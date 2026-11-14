//! Quantized latent semantic analysis of noun definitions. Used only as a
//! second opinion among already-proposed spelling candidates.
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};
const D: usize = 80;
const BYTES: &[u8] = include_bytes!("../model/semantics/vectors.i8");
static VOCAB: LazyLock<HashMap<&'static str, usize>> = LazyLock::new(|| {
    let v: HashMap<_, _> = include_str!("../model/semantics/vocab.txt")
        .lines()
        .enumerate()
        .map(|(i, w)| (w, i))
        .collect();
    assert_eq!(&BYTES[..4], b"MBS2");
    assert_eq!(
        u32::from_le_bytes(BYTES[4..8].try_into().unwrap()) as usize,
        v.len()
    );
    assert_eq!(
        u32::from_le_bytes(BYTES[8..12].try_into().unwrap()) as usize,
        D
    );
    assert_eq!(BYTES.len(), 12 + D * v.len());
    v
});
fn id(w: &str) -> Option<usize> {
    VOCAB.get(w).copied().or_else(|| {
        if let Some(stem) = w.strip_suffix("ies") {
            if let Some(i) = VOCAB.get(format!("{stem}y").as_str()) {
                return Some(*i);
            }
        }
        for suffix in ["es", "s", "ing", "ed"] {
            if let Some(i) = w.strip_suffix(suffix).and_then(|s| VOCAB.get(s)) {
                return Some(*i);
            }
        }
        None
    })
}
fn determiner(w: &str) -> bool {
    matches!(
        w,
        "the"
            | "a"
            | "an"
            | "my"
            | "your"
            | "our"
            | "their"
            | "his"
            | "her"
            | "another"
            | "this"
            | "that"
    )
}
const STOP:&str="will would could should might must want wanted went got get gets take took taking put found find just really also again there here today yesterday tomorrow still said told left right back front thing things sure make made think come came going before after when until around down over into near went last next way asked looking brought bring gave every another time upstairs downstairs something someone getting had have did done how him her his our was not the for its all that from with and are were mine can you this that those there what she one two";
static STOP_WORDS: LazyLock<std::collections::HashSet<&str>> =
    LazyLock::new(|| STOP.split_whitespace().collect());
fn similarity(a: usize, b: usize) -> f32 {
    let row = |id: usize| &BYTES[12 + id * D..12 + (id + 1) * D];
    row(a)
        .iter()
        .zip(row(b))
        .map(|(&x, &y)| i32::from(x as i8) * i32::from(y as i8))
        .sum::<i32>() as f32
        / (127. * 127.)
}
// Adjacent transpositions / extra repeated letter: accept only an independent
// first candidate that exactly reconstructs the literal by undoing one slip.
fn mechanical(t: &str, w: &str) -> bool {
    let (a, b) = (t.as_bytes(), w.as_bytes());
    if a.len() == b.len() {
        let Some(i) = a.iter().zip(b).position(|(x, y)| x != y) else {
            return false;
        };
        i + 1 < a.len() && a[i] == b[i + 1] && a[i + 1] == b[i] && a[i + 2..] == b[i + 2..]
    } else if a.len() == b.len() + 1 {
        (0..b.len()).any(|i| a[i] == a[i + 1] && a[..i] == b[..i] && a[i + 1..] == b[i..])
    } else {
        false
    }
}
fn one_edit(a: &str, b: &str) -> bool {
    let (mut s, mut l) = (a.as_bytes(), b.as_bytes());
    if s.len() > l.len() {
        std::mem::swap(&mut s, &mut l);
    }
    if s.len() == l.len() {
        return s.iter().zip(l).filter(|(x, y)| x != y).count() == 1 || mechanical(a, b);
    }
    if s.len() + 1 != l.len() {
        return false;
    }
    let i = s.iter().zip(l).position(|(x, y)| x != y).unwrap_or(s.len());
    s[i..] == l[i + 1..]
}
fn pick(ctx: &str, t: &str, base: &str, words: &[&str]) -> Option<usize> {
    if t.len() < 4 || !t.bytes().all(|c| c.is_ascii_lowercase()) || id(t).is_some() {
        return None;
    }
    let first = *words.first()?;
    if base == t
        && t.len() >= 5
        && super::WORDS.get(first).copied().unwrap_or(0) >= 3
        && mechanical(t, first)
    {
        return Some(0);
    }
    if mechanical(t, base) {
        return None;
    }
    let sentence = ctx
        .rsplit(['.', '?', '!', '\n'])
        .next()?
        .to_ascii_lowercase();
    let mut tokens = sentence
        .split(|c: char| !c.is_ascii_lowercase())
        .filter(|w| !w.is_empty())
        .rev()
        .take(128);
    if !determiner(tokens.next()?) {
        return None;
    }
    let mut cues = Vec::new();
    for w in tokens {
        if w.len() < 3 || determiner(w) || STOP_WORDS.contains(w) {
            continue;
        }
        if let Some(i) = id(w) {
            if !cues.contains(&i) {
                cues.push(i);
            }
        }
    }
    if cues.is_empty() {
        return None;
    }
    let mut scored = Vec::new();
    for (i, &w) in words.iter().enumerate() {
        if !one_edit(t, w) {
            continue;
        }
        let Some(j) = id(w) else { continue };
        let (mut peak, mut second) = (0f32, 0f32);
        for &cue in &cues {
            let x = similarity(cue, j);
            if x > peak {
                second = peak;
                peak = x
            } else {
                second = second.max(x)
            }
        }
        let score = peak + 0.24 * second - if t.len() == w.len() { 0. } else { 0.38 };
        scored.push((score, i, peak));
    }
    if scored.len() < 2 {
        return None;
    }
    scored.sort_by(|x, y| y.0.total_cmp(&x.0).then(x.1.cmp(&y.1)));
    let (s, i, peak) = scored[0];
    (peak >= 0.60 && s - scored[1].0 >= 0.24 && words[i].len() == t.len()).then_some(i)
}
/// # Safety
/// Four borrowed NUL-terminated UTF-8 strings; returns a zero-based candidate
/// index, or -1 to retain the existing policy. No text crosses call boundaries.
#[no_mangle]
pub unsafe extern "C" fn mb_refine_v1(
    ctx: *const c_char,
    typed: *const c_char,
    base: *const c_char,
    pool: *const c_char,
) -> i32 {
    if [ctx, typed, base, pool].iter().any(|p| p.is_null()) {
        return -1;
    }
    std::panic::catch_unwind(|| {
        let [Ok(c), Ok(t), Ok(b), Ok(p)] =
            [ctx, typed, base, pool].map(|s| unsafe { CStr::from_ptr(s) }.to_str())
        else {
            return -1;
        };
        if c.len() > 8192 || t.len() > 40 || b.len() > 160 || p.len() > 4096 {
            return -1;
        }
        let words = p.split('\t').take(24).collect::<Vec<_>>();
        pick(c, t, b, &words).map_or(-1, |i| i as i32)
    })
    .unwrap_or(-1)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn boots_are_not_an_exception_table() {
        let pool = ["book", "blog", "boo", "boot", "bug", "boom", "bog"];
        assert_eq!(
            pick(
                "My left foot was getting wet when I went back upstairs to find the ",
                "boog",
                "book",
                &pool
            ),
            Some(3)
        );
        assert_ne!(
            pick(
                "My left foot was getting wet. Where did I leave the ",
                "boog",
                "book",
                &pool
            ),
            Some(3)
        );
        assert_ne!(
            pick(
                "I left my library card in my pocket when I went back upstairs to find the ",
                "boog",
                "book",
                &pool
            ),
            Some(3)
        );
        assert_eq!(
            pick("I found my shoe and the ", "boot", "boot", &pool),
            None
        );
    }
    #[test]
    fn only_exact_mechanical_edits() {
        assert!(mechanical("sttaff", "staff"));
        assert!(mechanical("flwoer", "flower"));
        assert!(!mechanical("sttaff", "stuff"));
        assert!(!mechanical("flwoer", "flow"));
        assert!(!mechanical("staff", "staff"));
    }
}
