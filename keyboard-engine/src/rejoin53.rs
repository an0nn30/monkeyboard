//! High-confidence cuts through ordinary words. Case and whitespace are checked
//! by the caller before two displayed fragments can be replaced.
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};

static CUTS: LazyLock<HashMap<&'static str, u32>> = LazyLock::new(|| {
    include_str!("../model/rejoin53/cuts.tsv")
        .lines()
        .filter_map(|r| {
            let (s, n) = r.split_once('\t')?;
            Some((s, n.parse().ok()?))
        })
        .collect()
});

fn accepts(a: &str, b: &str) -> bool {
    if a.is_empty()
        || b.is_empty()
        || a.len() + b.len() > 20
        || !a.bytes().all(|c| c.is_ascii_alphabetic())
        || !b.bytes().all(|c| c.is_ascii_lowercase())
        || !a.bytes().skip(1).all(|c| c.is_ascii_lowercase())
    {
        return false;
    }
    let mut joined = a.to_ascii_lowercase();
    joined.push_str(b);
    CUTS.get(joined.as_str())
        .is_some_and(|cuts| cuts & (1 << a.len()) != 0)
}
#[no_mangle]
pub unsafe extern "C" fn mb_rejoin53_v1(a: *const c_char, b: *const c_char) -> i32 {
    if a.is_null() || b.is_null() {
        return 0;
    }
    match (CStr::from_ptr(a).to_str(), CStr::from_ptr(b).to_str()) {
        (Ok(a), Ok(b)) => accepts(a, b) as i32,
        _ => 0,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literal_word_boundaries_and_names_are_not_fragments() {
        for (a, b) in [
            ("a", "way"),
            ("my", "self"),
            ("can", "not"),
            ("in", "to"),
            ("Jo", "Ann"),
            ("a", "b"),
            ("", "x"),
        ] {
            assert!(!accepts(a, b), "{a} {b}");
        }
    }
}
