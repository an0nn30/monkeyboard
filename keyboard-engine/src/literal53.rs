//! A calibrated veto for proposed automatic edits. The model uses aggregate
//! word/slot counts from training and punctuation-independent register cues.
use std::ffi::{c_char, CStr};

const LEX: &[u8] = include_bytes!("../model/literal53/lex.bin");
const CHANNEL: &[u8] = include_bytes!("../model/literal53/channel.bin");
const RANK: &[u8] = include_bytes!("../model/literal53/rank.bin");
const REGISTER: &[u8] = include_bytes!("../model/literal53/register.bin");
const NF: usize = 52;
const STRATA: usize = 4;

fn key(text: &str) -> u64 {
    text.bytes().fold(14695981039346656037, |h, c| {
        (h ^ u64::from(c)).wrapping_mul(1099511628211)
    })
}

fn record(data: &'static [u8], size: usize, word: &str) -> Option<&'static [u8]> {
    let target = key(word);
    let (mut lo, mut hi) = (0, data.len() / size);
    while lo < hi {
        let mid = (lo + hi) / 2;
        let row = &data[mid * size..(mid + 1) * size];
        match u64::from_le_bytes(row[..8].try_into().unwrap()).cmp(&target) {
            std::cmp::Ordering::Less => lo = mid + 1,
            std::cmp::Ordering::Greater => hi = mid,
            std::cmp::Ordering::Equal => return Some(&row[8..]),
        }
    }
    None
}

fn lexical(word: &str) -> [f32; 5] {
    let Some(row) = record(LEX, 18, word) else {
        return [0.; 5];
    };
    std::array::from_fn(|i| f32::from(u16::from_le_bytes([row[2 * i], row[2 * i + 1]])))
}

fn literal_style(general: f32, sms: f32) -> f32 {
    ((sms + 0.08) / (general + 1.) * 12.).ln().clamp(0., 4.)
}

fn tokens(text: &str) -> impl DoubleEndedIterator<Item = &str> {
    text.split(|c: char| !(c.is_ascii_alphabetic() || c == '\''))
        .map(|s| s.trim_matches('\''))
        .filter(|s| !s.is_empty())
}

fn register_weight(term: &str) -> f32 {
    record(REGISTER, 12, term).map_or(0., |r| f32::from_le_bytes(r.try_into().unwrap()))
}

fn domain(left: &str, typed: &str, right: &str) -> f32 {
    let mut words: Vec<_> = tokens(left).rev().take(12).collect();
    words.reverse();
    words.push(typed);
    words.extend(tokens(right).take(3));
    let mut z = register_weight("");
    for (i, w) in words.iter().enumerate() {
        if !words[..i].contains(w) {
            z += register_weight(w);
        }
    }
    for (i, pair) in words.windows(2).enumerate() {
        if !words[..i + 1].windows(2).any(|seen| seen == pair) {
            z += register_weight(&format!("{} {}", pair[0], pair[1]));
        }
    }
    (z + 1.).clamp(0., 4.)
}

fn edit_distance(a: &[u8], b: &[u8]) -> usize {
    // The caller bounds candidate strings to 64 ASCII bytes.
    let mut prev: [u8; 65] = std::array::from_fn(|i| i as u8);
    let mut older = prev;
    for (i, x) in a.iter().enumerate() {
        let mut row = [0u8; 65];
        row[0] = (i + 1) as u8;
        for (j, y) in b.iter().enumerate() {
            row[j + 1] = (prev[j + 1] + 1)
                .min(row[j] + 1)
                .min(prev[j] + u8::from(x != y));
            if i > 0 && j > 0 && *x == b[j - 1] && *y == a[i - 1] {
                row[j + 1] = row[j + 1].min(older[j - 1] + 1);
            }
        }
        older = prev;
        prev = row;
    }
    usize::from(prev[b.len()])
}

fn score(left: &str, typed: &str, right: &str, replacement: &str) -> Option<f32> {
    let trim_marks = |c: char| !(c.is_ascii_alphabetic() || c == '\'' || c == ' ');
    let typed = typed.trim_matches(trim_marks);
    let replacement = replacement.trim_matches(trim_marks);
    if !(1..=40).contains(&typed.len())
        || replacement.is_empty()
        || replacement.len() > 64
        || !typed.bytes().all(|b| b.is_ascii_alphabetic() || b == b'\'')
        || !replacement
            .bytes()
            .all(|b| b.is_ascii_alphabetic() || b == b'\'' || b == b' ')
        || typed.eq_ignore_ascii_case(replacement)
    {
        return None;
    }
    let w = typed.to_ascii_lowercase();
    let v = replacement.to_ascii_lowercase();
    let [general, sms, caps, _, _] = lexical(&w);
    let dst = lexical(&v);
    let left = left.to_ascii_lowercase();
    let right = right.to_ascii_lowercase();
    let before = tokens(&left).rev().take(8);
    let after = tokens(&right).take(3);
    let mut name_slot: f32 = 0.;
    let mut style: f32 = 0.;
    let mut style_sum: f32 = 0.;
    let mut unknown: f32 = 0.;
    let repeated = tokens(&left).chain(tokens(&right)).any(|token| token == w);
    let mut medial = false;
    for (side, words) in [before.collect::<Vec<_>>(), after.collect::<Vec<_>>()]
        .into_iter()
        .enumerate()
    {
        if side == 0 {
            medial = !words.is_empty();
        }
        for (i, word) in words.into_iter().enumerate() {
            let counts = lexical(word);
            let count = counts[0] + counts[1];
            let word_style = literal_style(counts[0], counts[1]);
            style = style.max(word_style);
            style_sum += word_style;
            unknown += f32::from(count == 0.);
            if i == 0 {
                name_slot = name_slot.max((counts[3 + side] / (count + 2.)).min(1.));
            }
        }
    }
    let name = caps / (general + sms + 0.5);
    let upper = f32::from(
        medial
            && typed.split('\'').filter(|s| !s.is_empty()).all(|s| {
                s.as_bytes()[0].is_ascii_uppercase()
                    && !s.as_bytes()[1..].iter().any(u8::is_ascii_uppercase)
            }),
    );
    let local = literal_style(general, sms);
    let stripped = f32::from(
        w.bytes()
            .filter(|&b| b != b'\'')
            .eq(v.bytes().filter(|&b| b != b'\'')),
    );
    let suffix = f32::from(w.ends_with("in") && v.strip_suffix('g') == Some(w.as_str()));
    let direction = record(CHANNEL, 10, &format!("{w} {v}"))
        .map_or(0., |r| f32::from(u16::from_le_bytes([r[0], r[1]])).ln_1p());
    let absent = f32::from(general == 0.);
    let short = f32::from(w.len() < 4);
    let unknown = unknown.min(3.);
    let casualness = domain(&left, &w, &right);
    let edit = edit_distance(w.as_bytes(), v.replace(' ', "").as_bytes()).min(4) as f32;
    let stratum = if stripped == 1. {
        0
    } else if sms > 0. && sms >= general {
        1
    } else if general == 0. {
        2
    } else {
        3
    };
    let features: [f32; NF] = [
        1.,
        (w.len().min(12) as f32) / 6.,
        short,
        upper,
        f32::from(w.len() > 1 && !typed.bytes().any(|b| b.is_ascii_lowercase())),
        general.ln_1p(),
        sms.ln_1p(),
        dst[0].ln_1p(),
        local,
        style,
        style_sum.min(8.),
        unknown,
        name,
        name_slot,
        upper * name_slot,
        upper * name,
        f32::from(w.len() > 4) * absent,
        dst[1].ln_1p(),
        stripped,
        suffix,
        f32::from(v.contains(' ')),
        w.bytes().filter(|b| b"aeiou".contains(b)).count() as f32 / w.len() as f32,
        f32::from(w.as_bytes()[0] == v.as_bytes()[0]),
        w.len().abs_diff(v.len()) as f32,
        direction,
        direction * style,
        local * style,
        local * stripped,
        name_slot * absent,
        upper * absent,
        style * absent,
        unknown * absent,
        short * style,
        f32::from(sms > 0.) * absent,
        f32::from(dst[0] < 5.) * absent,
        suffix * style,
        stripped * style,
        f32::from(repeated),
        name * (1. - upper),
        f32::from(sms > 0. && dst[0] == 0.),
        casualness,
        casualness * stripped,
        casualness * absent,
        casualness * local,
        casualness * f32::from(sms > 0.),
        casualness * direction,
        casualness * edit,
        edit,
        edit * absent,
        f32::from(edit >= 2. && dst[0] < 4.),
        f32::from(edit >= 2.) * upper,
        f32::from(edit >= 2.) * name_slot,
    ];
    debug_assert_eq!(RANK.len(), 4 * (NF + STRATA));
    let weights = RANK
        .chunks_exact(4)
        .map(|r| f32::from_le_bytes(r.try_into().unwrap()));
    let threshold = weights.clone().nth(stratum).unwrap();
    let logit: f32 = features
        .into_iter()
        .zip(weights.skip(STRATA))
        .map(|(x, w)| x * w)
        .sum();
    Some(logit - threshold)
}

/// Input pointers are borrowed NUL-terminated UTF-8 for this call only.
/// # Safety
/// Non-null pointers must refer to readable NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn mb_keep_literal53_v1(
    left: *const c_char,
    typed: *const c_char,
    right: *const c_char,
    replacement: *const c_char,
) -> i32 {
    if [left, typed, right, replacement]
        .iter()
        .any(|p| p.is_null())
    {
        return 0;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(t), Ok(r), Ok(v)) = (read(left), read(typed), read(right), read(replacement))
    else {
        return 0;
    };
    if l.len() > 8192 || r.len() > 512 {
        return 0;
    }
    i32::from(score(l, t, r, v).is_some_and(|s| s >= 0.))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learned_veto_uses_the_word_and_its_neighbors() {
        for (left, typed, right, guess) in [
            ("Please text", "Zeretha", "about the bridge", "Beretta"),
            ("Hey", "Nivaan", "are you coming", "Nissan"),
            ("So wats ur opinion", "abt", "him", "at"),
        ] {
            assert!(score(left, typed, right, guess).is_some_and(|v| v >= 0.));
        }
        for (left, typed, right, guess) in [
            ("we need to", "recieve", "the parcels", "receive"),
            ("The", "brdige", "is open", "bridge"),
            ("I have a", "pear", "of shoes", "pair"),
        ] {
            assert!(score(left, typed, right, guess).is_some_and(|v| v < 0.));
        }
    }

    #[test]
    fn malformed_input_and_case_only_proposals_abstain() {
        assert!(score("", "AB", "", "ab").is_none());
        assert!(score("", "123", "", "the").is_none());
        assert!(score("", &"x".repeat(41), "", "a").is_none());
        assert!(score("", "hello", "", &"y".repeat(65)).is_none());
        let nil = std::ptr::null();
        assert_eq!(unsafe { mb_keep_literal53_v1(nil, nil, nil, nil) }, 0);
    }
}

const RESIDUAL_NAMES: &[u8] = include_bytes!("../model/name54/names.bin");
const ORIGINAL_NAMES: &[u8] = include_bytes!("../model/name54/originals.bin");

fn is_name54(word: &str, table: &'static [u8]) -> bool {
    word.len() >= 2
        && word.len() <= 40
        && word.bytes().all(|c| c.is_ascii_alphabetic())
        && record(table, 8, &word.to_ascii_lowercase()).is_some()
}

/// Veto a new residual proposal that introduces or rewrites a learned name.
/// # Safety
/// Non-null arguments must point to readable NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn mb_residual_name54_v1(
    typed: *const c_char,
    proposed: *const c_char,
) -> i32 {
    if typed.is_null() || proposed.is_null() {
        return 0;
    }
    let (Ok(typed), Ok(proposed)) = (
        unsafe { CStr::from_ptr(typed) }.to_str(),
        unsafe { CStr::from_ptr(proposed) }.to_str(),
    ) else {
        return 0;
    };
    i32::from(
        typed != proposed
            && (is_name54(typed, RESIDUAL_NAMES) || is_name54(proposed, RESIDUAL_NAMES)),
    )
}

/// Preserve an original with high confidence of use as a name on automatic paths.
/// # Safety
/// A non-null argument must point to a readable NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn mb_original_name54_v1(typed: *const c_char) -> i32 {
    if typed.is_null() {
        return 0;
    }
    let Ok(typed) = (unsafe { CStr::from_ptr(typed) }).to_str() else {
        return 0;
    };
    i32::from(is_name54(typed, ORIGINAL_NAMES))
}
