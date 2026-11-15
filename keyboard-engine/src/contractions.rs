//! Apostrophe-only spelling restoration using a corpus-trained clitic vocabulary.
//! The literal competes with the contracted form when both are English words.
use std::collections::HashMap;
use std::ffi::{c_char, CStr};
use std::sync::LazyLock;

struct Form {
    spelling: &'static str,
    contracted: f32,
    bare: f32,
    acronym: bool,
    ambiguous: bool,
    contexts: HashMap<&'static str, (f32, f32)>,
}

static FORMS: LazyLock<HashMap<&str, Form>> = LazyLock::new(|| {
    include_str!("../model/contractions.tsv")
        .lines()
        .map(|line| {
            let fields: Vec<_> = line.split('\t').collect();
            let number = |i: usize| fields[i].parse::<f32>().unwrap();
            let contexts = fields[7]
                .split_whitespace()
                .map(|feature| {
                    let mut parts = feature.rsplitn(3, ':');
                    let bare = parts.next().unwrap().parse().unwrap();
                    let contracted = parts.next().unwrap().parse().unwrap();
                    (parts.next().unwrap(), (contracted, bare))
                })
                .collect();
            (
                fields[0],
                Form {
                    spelling: fields[1],
                    contracted: number(2),
                    bare: number(3),
                    acronym: number(4) >= 3.0 && number(4) >= number(5) * 0.2,
                    ambiguous: fields[6] == "1",
                    contexts,
                },
            )
        })
        .collect()
});

fn decision(left: &str, typed: &str, right: &str) -> Option<&'static str> {
    if typed.len() < 2
        || typed.len() > 24
        || !typed.bytes().all(|b| b.is_ascii_alphabetic())
        || typed.as_bytes()[1..].iter().any(u8::is_ascii_uppercase)
    {
        return None;
    }
    let form = FORMS.get(typed.to_ascii_lowercase().as_str())?;
    if !form.ambiguous {
        return Some(form.spelling);
    }

    let left = left.trim_end();
    let previous = left
        .rsplit(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .next()
        .unwrap_or("");
    let next = right
        .trim_start()
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .next()
        .unwrap_or("");
    let at_start = left.is_empty() || left.ends_with(['.', '!', '?']);
    let count = |side: char, word: &str| {
        form.contexts
            .get(format!("{side}{}", word.to_ascii_lowercase()).as_str())
            .copied()
            .unwrap_or_default()
    };
    let (a, b) = if previous.is_empty() {
        (0.0, 0.0)
    } else {
        count('L', previous)
    };
    let (c, d) = if next.is_empty() {
        (0.0, 0.0)
    } else {
        count('R', next)
    };
    // A title-cased contraction of a normally capitalized pronoun and an
    // uppercase initialism have distinguishable surfaces at sentence start.
    let pronoun_case = form.spelling.as_bytes()[0].is_ascii_uppercase()
        && typed.as_bytes()[0].is_ascii_uppercase()
        && form.acronym;
    if pronoun_case && at_start && d <= c {
        return Some(form.spelling);
    }

    // Dialogue transcripts also omit apostrophes. Bound the unigram odds
    // in both directions so these noisy counts do not erase a clear pair.
    let prior = ((form.contracted + 1.) / (form.bare + 1.))
        .ln()
        .clamp(-1.5, 1.5);
    let evidence = |yes: f32, no: f32| {
        if yes + no < 2. {
            0.
        } else {
            ((yes + 0.25) / (no + 0.25)).ln() - prior
        }
    };
    let opening = if at_start && !next.is_empty() {
        let (yes, no) = count('L', "^");
        evidence(yes, no)
    } else {
        0.
    };
    let score = prior + evidence(a, b) + evidence(c, d) + opening;
    ((a >= 2. || c >= 2.) && score >= 2.0 && (b <= a || c > 2. * d) && (d <= c || a > 2. * b))
        .then_some(form.spelling)
}

/// A canonical spelling, or no suggestion. All pointers are borrowed for this call.
/// # Safety
/// Strings must be NUL terminated and out must hold capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_contraction_v1(
    left: *const c_char,
    typed: *const c_char,
    right: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if left.is_null() || typed.is_null() || right.is_null() || out.is_null() {
        return -1;
    }
    let (Ok(left), Ok(typed), Ok(right)) = (
        unsafe { CStr::from_ptr(left) }.to_str(),
        unsafe { CStr::from_ptr(typed) }.to_str(),
        unsafe { CStr::from_ptr(right) }.to_str(),
    ) else {
        return -1;
    };
    let Some(word) = decision(left, typed, right) else {
        return 0;
    };
    if word.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(word.as_ptr(), out.cast(), word.len());
        if typed.as_bytes()[0].is_ascii_uppercase() {
            *out = word.as_bytes()[0].to_ascii_uppercase() as c_char;
        }
        *out.add(word.len()) = 0;
    }
    1
}

pub(crate) fn conventional(word: &str) -> Option<&'static str> {
    if word.contains('\'') {
        let bare = word.replace('\'', "");
        let spelling = FORMS.get(bare.as_str())?.spelling;
        return (spelling != word && spelling.eq_ignore_ascii_case(word)).then_some(spelling);
    }
    decision("", word, "")
}
