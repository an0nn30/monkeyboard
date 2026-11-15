//! Context counts learned on disjoint conversations. Sorted fixed-width records
//! can be searched in the mapped binary without allocating a phrase dictionary.
use super::{observations, whole_compound, HashMap, LazyLock, WORDS};
static IDS: LazyLock<HashMap<&str, u16>> = LazyLock::new(|| {
    include_str!("../model/context21/vocab.txt")
        .lines()
        .enumerate()
        .map(|(i, w)| (w, (i + 1) as u16))
        .collect()
});
const COUNTS: &[u8] = include_bytes!("../model/context21/counts.bin");
static WEIGHTS: LazyLock<Vec<f64>> = LazyLock::new(|| {
    let v: Vec<_> = include_str!("../model/context21/boundary.txt")
        .split_whitespace()
        .map(|v| v.parse::<f64>().unwrap())
        .collect();
    assert_eq!(v.len(), 11);
    v
});
pub(super) fn count(words: impl IntoIterator<Item = impl AsRef<str>>) -> u32 {
    let mut code = 0u64;
    for w in words {
        let Some(id) = IDS.get(w.as_ref()) else {
            return 0;
        };
        code = (code << 16) | u64::from(*id);
    }
    let (mut lo, mut hi) = (0, COUNTS.len() / 10);
    while lo < hi {
        let i = (hi + lo) / 2;
        let row = &COUNTS[10 * i..10 * i + 10];
        match u64::from_le_bytes(row[..8].try_into().unwrap()).cmp(&code) {
            std::cmp::Ordering::Equal => return u16::from_le_bytes([row[8], row[9]]) as u32,
            std::cmp::Ordering::Less => lo = i + 1,
            _ => hi = i,
        }
    }
    0
}
pub(super) fn split(prev: &str, word: &str) -> Option<(i32, String)> {
    if !(4..=30).contains(&word.len())
        || !word.bytes().all(|x| x.is_ascii_lowercase() || x == 39)
        || WORDS.contains_key(word)
        || observations(word) > 0
        || whole_compound(word)
        || count([word]) > 0
    {
        return None;
    }
    let (mut top, mut next, mut at) = (f64::NEG_INFINITY, f64::NEG_INFINITY, 0);
    for i in 1..word.len() {
        let (a, b) = word.split_at(i);
        if (a.len() == 1 && a != "a" && a != "i") || (b.len() == 1 && b != "a" && b != "i") {
            continue;
        }
        let va = count([a]);
        let vb = count([b]);
        if va == 0 || vb == 0 {
            continue;
        }
        let inside = count([a, b]);
        let lead = count([prev, a]);
        if inside < 3 || (lead < 2 && inside < 25) {
            continue;
        }
        let [va, vb, inner, left] = [va, vb, inside, lead].map(|n| f64::from(n).ln_1p());
        let x = [
            1.,
            va,
            vb,
            inner,
            left,
            va.min(vb),
            inner.min(left),
            a.len().min(8) as f64,
            b.len().min(8) as f64,
            (a.len() == 1) as u8 as f64,
            (b.len() == 1) as u8 as f64,
        ];
        let score: f64 = x.iter().zip(WEIGHTS.iter()).map(|(x, w)| x * w).sum();
        if score > top {
            next = top;
            top = score;
            at = i
        } else {
            next = next.max(score)
        }
    }
    if top < 4.0 || top - next < 2.5 {
        None
    } else {
        Some((1, format!("{} {}", &word[..at], &word[at..])))
    }
}

/// Words with similar output embeddings can fit the same sentence but express
/// different intentions. Do not automatically substitute one for the other.
pub(super) fn confusable_meaning(a: &str, b: &str) -> bool {
    if a.len() != b.len() || !WORDS.contains_key(a) {
        return false;
    }
    static V: LazyLock<HashMap<&str, usize>> = LazyLock::new(|| {
        include_str!("../model/context21/short-vocab.txt")
            .lines()
            .enumerate()
            .map(|(i, w)| (w, i))
            .collect()
    });
    const DATA: &[u8] = include_bytes!("../model/context21/short-vectors.bin");
    const WIDTH: usize = 384;
    let (Some(&i), Some(&j)) = (V.get(a), V.get(b)) else {
        return false;
    };
    let (mut dot, mut aa, mut bb) = (0i32, 0i32, 0i32);
    for (&x, &y) in DATA[i * WIDTH..(i + 1) * WIDTH]
        .iter()
        .zip(&DATA[j * WIDTH..(j + 1) * WIDTH])
    {
        let (x, y) = (i32::from(x as i8), i32::from(y as i8));
        dot += x * y;
        aa += x * x;
        bb += y * y;
    }
    f64::from(dot) > 0.46 * (f64::from(aa) * f64::from(bb)).sqrt()
}
