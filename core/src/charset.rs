//! 终端字符编码转换：远端用 GBK、Big5 这类编码时，输出先转成 UTF-8 再交给终端，
//! 键盘输入（UTF-8）再转回远端的编码。用 encoding_rs（Firefox 用的那套），支持流式转换，
//! 一个汉字被拆在两次输出里也没关系。

use encoding_rs::{Decoder, Encoder, EncoderResult, Encoding, UTF_8};

/// 编码名（如 "GBK"、"GB18030"、"Big5"）→ encoding_rs 的编码；UTF-8 或空字符串返回 None（不用转换）
pub(crate) fn lookup(label: &str) -> Option<&'static Encoding> {
    let label = label.trim();
    if label.is_empty() {
        return None;
    }
    let encoding = Encoding::for_label(label.as_bytes())?;
    if encoding == UTF_8 { None } else { Some(encoding) }
}

/// 远端输出 → UTF-8
pub(crate) struct OutputDecoder {
    decoder: Option<Decoder>,
}

impl OutputDecoder {
    pub(crate) fn new(encoding: Option<&'static Encoding>) -> Self {
        Self {
            decoder: encoding.map(|e| e.new_decoder_without_bom_handling()),
        }
    }

    pub(crate) fn decode(&mut self, input: &[u8]) -> Vec<u8> {
        let Some(decoder) = &mut self.decoder else {
            return input.to_vec();
        };
        let capacity = decoder
            .max_utf8_buffer_length(input.len())
            .unwrap_or(input.len() * 3 + 16);
        let mut out = vec![0u8; capacity];
        // 缓冲按最大长度分配，不会出现输出满的情况；无法解码的字节变成 U+FFFD
        let (_, _, written, _) = decoder.decode_to_utf8(input, &mut out, false);
        out.truncate(written);
        out
    }
}

/// 键盘输入（UTF-8）→ 远端编码。远端编码里没有的字符（比如 emoji 之于 GBK）换成 '?'
pub(crate) struct InputEncoder {
    encoder: Option<Encoder>,
    /// 上一次末尾不完整的 UTF-8 字节
    pending: Vec<u8>,
}

impl InputEncoder {
    pub(crate) fn new(encoding: Option<&'static Encoding>) -> Self {
        Self {
            encoder: encoding.map(|e| e.new_encoder()),
            pending: Vec::new(),
        }
    }

    pub(crate) fn encode(&mut self, bytes: Vec<u8>) -> Vec<u8> {
        let Some(encoder) = &mut self.encoder else {
            return bytes;
        };
        let mut input = std::mem::take(&mut self.pending);
        input.extend_from_slice(&bytes);
        let text = match std::str::from_utf8(&input) {
            Ok(text) => text.to_string(),
            Err(e) if e.error_len().is_none() => {
                // 末尾的字符还没收全，留到下次
                let valid = e.valid_up_to();
                self.pending = input[valid..].to_vec();
                String::from_utf8_lossy(&input[..valid]).into_owned()
            }
            Err(_) => String::from_utf8_lossy(&input).into_owned(),
        };

        let mut out = Vec::with_capacity(text.len() * 2);
        let mut buffer = vec![
            0u8;
            encoder
                .max_buffer_length_from_utf8_without_replacement(text.len())
                .unwrap_or(text.len() * 4)
                + 16
        ];
        let mut rest = text.as_str();
        loop {
            let (result, read, written) =
                encoder.encode_from_utf8_without_replacement(rest, &mut buffer, false);
            out.extend_from_slice(&buffer[..written]);
            rest = &rest[read..];
            match result {
                EncoderResult::InputEmpty => break,
                EncoderResult::OutputFull => continue,
                EncoderResult::Unmappable(_) => out.push(b'?'),
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_needs_no_conversion() {
        assert!(lookup("UTF-8").is_none());
        assert!(lookup("utf8").is_none());
        assert!(lookup("").is_none());
        assert!(lookup("GBK").is_some());
        assert!(lookup("GB18030").is_some());
        assert!(lookup("Big5").is_some());
    }

    #[test]
    fn gbk_round_trip_with_split_characters() {
        let gbk = lookup("GBK");
        // “中文”的 GBK 编码是 D6 D0 CE C4，故意拆在两次输出中间
        let mut decoder = OutputDecoder::new(gbk);
        let mut text = decoder.decode(&[b'a', 0xD6]);
        text.extend(decoder.decode(&[0xD0, 0xCE, 0xC4, b'\n']));
        assert_eq!(String::from_utf8(text).unwrap(), "a中文\n");

        let mut encoder = InputEncoder::new(gbk);
        let bytes = "中".as_bytes();
        // UTF-8 的“中”也拆成两半输入
        let mut out = encoder.encode(bytes[..1].to_vec());
        out.extend(encoder.encode(bytes[1..].to_vec()));
        out.extend(encoder.encode("文😀\r".as_bytes().to_vec()));
        assert_eq!(out, vec![0xD6, 0xD0, 0xCE, 0xC4, b'?', b'\r']);
    }
}
