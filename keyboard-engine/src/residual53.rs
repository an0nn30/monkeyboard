//! Joint residual spelling and missing-space ranker. Each possible reversal
//! competes with the original surface and with every other admissible edit.
use super::{count, rivals, MODEL};
use std::{
    collections::HashSet,
    ffi::{c_char, CStr},
    sync::LazyLock,
};

const F: usize = 33;
type Features = [f32; F];

static KNOWN: LazyLock<HashSet<&str>> = LazyLock::new(|| {
    include_str!("../model/whole-compounds.txt")
        .lines()
        .chain(include_str!("../model/denoise22/literals.txt").lines())
        .chain(include_str!("../model/semantics/vocab.txt").lines())
        .collect()
});
static WEIGHTS: LazyLock<Vec<f32>> = LazyLock::new(|| {
    include_str!("../model/residual53/weights.txt")
        .split_whitespace()
        .map(|n| n.parse().unwrap())
        .collect()
});

fn segment(c: char) -> bool {
    !c.is_ascii_alphabetic() && c != '\''
}
fn id(word: &str) -> u16 {
    MODEL.ids.get(word).map_or(0, |i| i + 1)
}

pub(crate) fn candidates(left: &str, raw: &str, right: &str) -> Vec<(String, Features)> {
    let mut result = Vec::new();
    let bytes = raw.as_bytes();
    if !(3..=25).contains(&bytes.len())
        || !bytes.iter().all(|b| b.is_ascii_alphabetic() || *b == 39)
    {
        return result;
    }
    let title = bytes[0].is_ascii_uppercase();
    let doubled_cap =
        title && bytes[1] == bytes[0] && bytes[2..].iter().all(u8::is_ascii_lowercase);
    if !doubled_cap && bytes[1..].iter().any(u8::is_ascii_uppercase) {
        return result;
    }
    let raw = raw.to_ascii_lowercase();
    if MODEL.ids.contains_key(raw.as_str()) || KNOWN.contains(raw.as_str()) {
        return result;
    }
    let stop = ['.', '!', '?', ';', ':', '\n'];
    let left = left.rsplit(stop).next().unwrap_or("").to_ascii_lowercase();
    let right = right.split(stop).next().unwrap_or("").to_ascii_lowercase();
    let mut ls = left.split(segment).filter(|w| !w.is_empty()).rev();
    let mut rs = right.split(segment).filter(|w| !w.is_empty());
    let start = id("^");
    let b = ls.next().map_or(start, id);
    let a = ls.next().map_or(start, id);
    let d = rs.next().map_or(0, id);
    let e = rs.next().map_or(0, id);
    if title && b != start {
        return result;
    }
    let mut offer = |first: u16, second: Option<u16>, cost: f32| {
        let p = &MODEL.words[first as usize];
        let last = second.unwrap_or(first);
        let q = &MODEL.words[last as usize];
        let first_id = first + 1;
        let last_id = last + 1;
        let between = if second.is_some() {
            count(0, first_id, last_id)
        } else {
            0.
        };
        let lc = count(0, b, first_id);
        let rc = if d != 0 { count(0, last_id, d) } else { 0. };
        let ll = count(a, b, first_id);
        let rr = if e != 0 { count(last_id, d, e) } else { 0. };
        let mid = if second.is_some() {
            count(b, first_id, last_id).max(if d != 0 {
                count(first_id, last_id, d)
            } else {
                0.
            })
        } else if d != 0 {
            count(b, first_id, d)
        } else {
            0.
        };
        let is_split = second.is_some();
        let text = p.text;
        let shorter = raw.len().min(text.len());
        let (mut mismatches, mut swapped, mut duplicate) = (0, false, false);
        if !is_split {
            if raw.len() == text.len() {
                mismatches = raw
                    .bytes()
                    .zip(text.bytes())
                    .filter(|(a, b)| a != b)
                    .count();
                swapped = mismatches == 2;
            } else if raw.len() == text.len() + 1 {
                duplicate = raw.as_bytes().windows(2).enumerate().any(|(k, v)| {
                    v[0] == v[1] && raw[..k] == text[..k] && raw[k + 1..] == text[k..]
                });
            }
        }
        let repetitions = if is_split {
            0.
        } else {
            MODEL
                .attested
                .get(raw.as_str())
                .and_then(|r| r.iter().find(|(i, _)| *i == first))
                .map_or(0., |(_, n)| f32::from(*n).ln_1p())
        };
        let bit = |v| if v { 1. } else { 0. };
        let features = [
            1.,
            bit(is_split),
            raw.len().min(14) as f32,
            bit(raw.len() <= 4),
            p.c.min(q.c),
            p.c.max(q.c),
            p.e.min(q.e),
            p.e.max(q.e),
            p.s.min(q.s),
            p.s.max(q.s),
            lc,
            rc,
            lc.min(rc),
            between,
            ll,
            rr,
            mid,
            ll.max(rr).max(mid),
            cost,
            bit(swapped),
            bit(duplicate),
            bit(!is_split && text.len() > raw.len()),
            bit(!is_split && mismatches == 1),
            repetitions,
            bit(is_split && text.len().min(q.text.len()) == 1),
            bit(is_split && text.len().min(q.text.len()) == 2),
            bit(is_split) * (text.len().min(q.text.len()).min(7) as f32),
            bit(b == start),
            bit(d != 0),
            bit(doubled_cap),
            bit(!is_split && shorter <= 3),
            bit(is_split) * lc.max(rc),
            bit(is_split) * between.min(lc.max(rc)),
        ];
        let mut spelling = if is_split {
            format!("{} {}", p.text, q.text)
        } else {
            p.text.to_owned()
        };
        // Only transfer casing actually present in the raw surface.
        if title {
            spelling[..1].make_ascii_uppercase();
        }
        result.push((spelling, features));
    };
    for (idx, cost) in rivals(&raw) {
        if !doubled_cap || MODEL.words[idx as usize].text == &raw[1..] {
            offer(idx, None, cost);
        }
    }
    if !doubled_cap {
        for i in 1..raw.len() {
            let (Some(&first), Some(&second)) =
                (MODEL.ids.get(&raw[..i]), MODEL.ids.get(&raw[i..]))
            else {
                continue;
            };
            let p = &MODEL.words[first as usize];
            let q = &MODEL.words[second as usize];
            if p.candidate
                && q.candidate
                && p.text.bytes().any(|x| x.is_ascii_alphabetic())
                && q.text.bytes().any(|x| x.is_ascii_alphabetic())
            {
                offer(first, Some(second), 0.);
            }
        }
    }
    result
}

fn repair(left: &str, raw: &str, right: &str) -> Option<String> {
    let w = &*WEIGHTS;
    let mut best = None;
    let options = candidates(left, raw, right);
    let sole_candidate = options.len() == 1;
    let (mut top, mut next) = (0., f32::NEG_INFINITY);
    for (s, x) in options {
        let score = x.iter().zip(w).map(|(a, b)| a * b).sum::<f32>();
        if score > top {
            next = top;
            top = score;
            best = Some((s, x[19] != 0.));
        } else {
            next = next.max(score);
        }
    }
    let (best, swapped) = best?;
    let gate = if best.contains(' ') && sole_candidate {
        F + 4
    } else if swapped {
        F + 6
    } else if best.contains(' ') {
        F
    } else {
        F + 2
    };
    (top >= w[gate] && top - next >= w[gate + 1]).then_some(best)
}

/// # Safety
/// Inputs must point to NUL-terminated UTF-8. The caller owns capacity bytes at out.
#[no_mangle]
pub unsafe extern "C" fn mb_residual53_v1(
    left: *const c_char,
    typed: *const c_char,
    right: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if left.is_null() || typed.is_null() || right.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    *out = 0;
    let read = |p| CStr::from_ptr(p).to_str();
    let (Ok(l), Ok(t), Ok(r)) = (read(left), read(typed), read(right)) else {
        return -1;
    };
    if l.len() > 2048 || r.len() > 2048 {
        return 0;
    }
    let Some(s) = repair(l, t, r) else {
        return 0;
    };
    if s.len() >= capacity {
        return -1;
    }
    std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
    *out.add(s.len()) = 0;
    1
}

#[cfg(test)]
mod tests {
    use super::repair;
    #[test]
    fn separates_a_missing_space_and_reverses_a_transposition() {
        assert_eq!(
            repair("please wear your ", "safetyglasses", " in the workshop").as_deref(),
            Some("safety glasses")
        );
        assert_eq!(
            repair("the ice ", "meltde", " quickly").as_deref(),
            Some("melted")
        );
    }
    #[test]
    fn leaves_compounds_identifiers_and_mid_sentence_names_alone() {
        for raw in ["airport", "CamelCase", "x509", "Arunvel"] {
            assert_eq!(repair("see ", raw, " later"), None);
        }
    }
}
