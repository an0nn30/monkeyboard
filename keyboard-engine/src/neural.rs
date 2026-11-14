//! Sentence-level causal attention, trained offline. Quantized tables are
//! borrowed directly from the executable image; no decoded weight cache.
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};

const D: usize = 64;
const V: usize = 8192;
const W: &[u8] = include_bytes!("../model/neural/weights.i8");
static VOCAB: LazyLock<HashMap<&'static str, usize>> = LazyLock::new(|| {
    include_str!("../model/neural/vocab.txt")
        .lines()
        .enumerate()
        .map(|(i, s)| (s, i))
        .collect()
});

struct Table {
    bytes: &'static [u8],
    scale: f32,
}
impl Table {
    fn take(offset: &mut usize, len: usize) -> Self {
        let scale = f32::from_le_bytes(W[*offset..*offset + 4].try_into().unwrap());
        *offset += 4;
        let bytes = &W[*offset..*offset + len];
        *offset += len;
        Self { bytes, scale }
    }
    fn get(&self, i: usize) -> f32 {
        (self.bytes[i] as i8) as f32 * self.scale
    }
    fn dot(&self, row: usize, v: &[f32]) -> f32 {
        self.bytes[row * v.len()..(row + 1) * v.len()]
            .iter()
            .zip(v)
            .map(|(&x, y)| (x as i8) as f32 * y)
            .sum::<f32>()
            * self.scale
    }
}
static MODEL: LazyLock<[Table; 8]> = LazyLock::new(|| {
    assert_eq!(&W[..4], b"MBS1");
    assert_eq!(u32::from_le_bytes(W[4..8].try_into().unwrap()) as usize, V);
    assert_eq!(u32::from_le_bytes(W[8..12].try_into().unwrap()) as usize, D);
    let mut p = 12;
    let tables =
        [V * D, V * D, V * D, V * D, 2 * D * D, D, V * D, V].map(|n| Table::take(&mut p, n));
    assert_eq!(p, W.len());
    tables
});

fn encode(context: &str) -> Option<[f32; D]> {
    let sentence = context
        .rsplit(['.', '!', '?', '\n'])
        .next()?
        .to_ascii_lowercase()
        .replace('’', "'");
    let ids = sentence
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|w| !w.trim_matches('\'').is_empty())
        .rev()
        .take(128)
        .map(|w| *VOCAB.get(w.trim_matches('\'')).unwrap_or(&0))
        .collect::<Vec<_>>();
    if ids.is_empty() {
        return None;
    }
    let [e, q, k, v, h, hb, _, _] = &*MODEL;
    let last = ids[0];
    let mut query = [0.; D];
    let mut input = [0.; D * 2];
    for i in 0..D {
        query[i] = q.get(last * D + i);
        input[i] = e.get(last * D + i);
    }
    let mut attn = Vec::with_capacity(ids.len() + 1);
    for id in ids.iter().copied().chain(std::iter::once(1)) {
        attn.push((id, k.dot(id, &query) / (D as f32).sqrt()));
    }
    let high = attn.iter().fold(f32::NEG_INFINITY, |a, x| a.max(x.1));
    let mut sum = 0.;
    for (id, s) in attn {
        let weight = (s - high).exp();
        sum += weight;
        for (j, x) in input[D..].iter_mut().enumerate() {
            *x += weight * v.get(id * D + j);
        }
    }
    for x in &mut input[D..] {
        *x /= sum;
    }
    Some(std::array::from_fn(|i| {
        (h.dot(i, &input) + hb.get(i)).tanh()
    }))
}

/// # Safety
/// NUL-terminated inputs and capacity writable floats. Scores are comparable
/// within this call only. Unknown candidates receive negative infinity.
#[no_mangle]
pub unsafe extern "C" fn mb_sentence_scores_v1(
    context: *const c_char,
    candidates: *const c_char,
    out: *mut f32,
    capacity: usize,
) -> i32 {
    if context.is_null() || candidates.is_null() || out.is_null() || capacity == 0 || capacity > 64
    {
        return -1;
    }
    std::panic::catch_unwind(|| {
        let (Ok(ctx), Ok(items)) = (
            unsafe { CStr::from_ptr(context) }.to_str(),
            unsafe { CStr::from_ptr(candidates) }.to_str(),
        ) else {
            return -1;
        };
        if ctx.len() > 8192 || items.len() > 4096 {
            return -1;
        }
        let Some(hidden) = encode(ctx) else { return 0 };
        let [_, _, _, _, _, _, weights, bias] = &*MODEL;
        let mut n = 0;
        for word in items.split('\t') {
            if n == capacity {
                return -1;
            }
            let score = VOCAB
                .get(word)
                .map(|&i| weights.dot(i, &hidden) + bias.get(i))
                .unwrap_or(f32::NEG_INFINITY);
            unsafe { *out.add(n) = score };
            n += 1;
        }
        n as i32
    })
    .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sentence_boundary_and_long_range() {
        assert_eq!(encode("An unrelated topic. I left my"), encode("I left my"));
        assert_ne!(
            encode("The flight was delayed but I still went into the office to see the"),
            encode("The dentist was sick but I still went into the office to see the")
        );
        assert!(encode("Hello! ").is_none());
        assert_eq!(VOCAB.len(), V);
    }
}
