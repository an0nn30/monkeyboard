use std::{
    ffi::{c_char, CStr},
    sync::LazyLock,
};

// The glide vocabulary already ships in the extension. Keep views into its
// read-only word data and convert Zipf scores to frequencies once.
static WORDS: LazyLock<Vec<(&str, f32)>> = LazyLock::new(|| {
    include_str!("../model/glide-words.tsv")
        .lines()
        .filter_map(|line| {
            let (word, score) = line.split_once('\t')?;
            Some((word, 10_f32.powf(score.parse::<f32>().ok()? / 100.)))
        })
        .collect()
});

fn odds(before: &[u8], point: u8, other: u8, neighbors: &[u32]) -> f32 {
    let Ok(before) = std::str::from_utf8(before) else {
        return 1.;
    };
    let (left, prefix) = before
        .rsplit_once(char::is_whitespace)
        .unwrap_or(("", before));
    let prefix = prefix.as_bytes();
    if prefix.len() > 8
        || !prefix.iter().all(u8::is_ascii_lowercase)
        || !point.is_ascii_lowercase()
        || !other.is_ascii_lowercase()
        || point == other
    {
        return 1.;
    }
    let mut masses = [30.; 2];
    let previous = left.split_whitespace().next_back().filter(|word| {
        prefix.len() >= 2 && word.len() <= 24 && word.bytes().all(|c| c.is_ascii_lowercase())
    });
    let weights = [1., 0.03, 0.0009];
    let mut pairs = [0_f32; 2];
    let mut closest = 2;
    for &(word, frequency) in WORDS.iter() {
        let bytes = word.as_bytes();
        let Some(&next) = bytes.get(prefix.len()) else {
            continue;
        };
        let side = if next == point {
            0
        } else if next == other {
            1
        } else {
            continue;
        };
        let mut slips = 0;
        for (&observed, &candidate) in prefix.iter().zip(bytes) {
            if observed == candidate {
                continue;
            }
            if !super::adjacent(observed, candidate, neighbors) || slips == 2 {
                slips = 3;
                break;
            }
            slips += 1;
        }
        // A neighboring slip in the earlier prefix is possible, but much
        // weaker evidence than the letters that were actually emitted.
        if slips <= 2 {
            let weight = weights[slips];
            masses[side] += frequency * weight;
            closest = closest.min(slips);
            if let Some(previous) = previous {
                pairs[side] += super::context21::count([previous, word]) as f32 * weight;
            }
        }
    }
    let unigram = masses[1] / masses[0];
    // A pair with the best available prefix match counts as one observation.
    // Weaker prefix matches retain their slip penalty. Add one observation
    // distributed according to the general English prior to smooth sparse pairs.
    let evidence = pairs.map(|count| count / weights[closest]);
    if evidence[1] < 3. || evidence[1] <= evidence[0] {
        return unigram;
    }
    let prior = masses[1] / (masses[0] + masses[1]);
    let conditional = (evidence[1] + prior) / (evidence[0] + (1. - prior));
    unigram.max(conditional)
}

/// Relative English prefix support for two ASCII next letters. A ratio of one
/// abstains. No document or contact data is retained.
/// # Safety
/// The preceding text must be NUL-terminated. A non-null masks pointer must hold 26 u32s.
#[no_mangle]
pub unsafe extern "C" fn mb_edge_letter_odds_v1(
    before: *const c_char,
    point: u8,
    other: u8,
    masks: *const u32,
) -> f32 {
    if before.is_null() {
        return 1.;
    }
    let masks = if masks.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(masks, 26) }
    };
    odds(
        unsafe { CStr::from_ptr(before) }.to_bytes(),
        point,
        other,
        masks,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_prefix_favors_an_attested_continuation() {
        assert!(odds(b"chil", b'q', b'd', &[]) > 3.);
        assert!(odds(b"chil", b'd', b'q', &[]) < 1. / 3.);
    }

    #[test]
    fn previous_word_can_corroborate_a_different_continuation() {
        let isolated = odds(b"na", b't', b'm', &[]);
        assert!(isolated < 1.);
        assert!(odds(b"your na", b't', b'm', &[]) > 3.);
        assert_eq!(odds(b"xzq na", b't', b'm', &[]), isolated);
    }

    #[test]
    fn earlier_slip_requires_a_neighbor_on_the_displayed_layout() {
        assert_eq!(odds(b"chzl", b'q', b'd', &[]), 1.);
        let mut masks = [0; 26];
        masks[usize::from(b'z' - b'a')] = 1 << (b'i' - b'a');
        assert!(odds(b"chzl", b'q', b'd', &masks) > 3.);
    }

    #[test]
    fn unavailable_or_unsupported_prefix_is_neutral() {
        for prefix in [b"pi9".as_slice(), b"ninechars", b"\xc3\xa9"] {
            assert_eq!(odds(prefix, b'q', b'a', &[]), 1.);
        }
        assert_eq!(
            unsafe { mb_edge_letter_odds_v1(std::ptr::null(), b'q', b'a', std::ptr::null()) },
            1.
        );
    }
}
