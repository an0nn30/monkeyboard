//! Resolve conflicting long-word readings using swipe evidence shared across words.
use super::{rank, resample, Match, Point, Stroke, Word};

const COUNT: usize = 9;
const WEIGHTS: [f32; COUNT + 1] = include!("../model/glide-choice.weights");
type Features = [f32; COUNT];

fn margin(ranked: &[Match]) -> f32 {
    ranked
        .get(1)
        .map_or(3., |other| other.cost - ranked[0].cost)
}

struct PathFit {
    ordered_error: f32,
    length_error: f32,
    start_error: f32,
    end_error: f32,
}

// Minimum distance to each intended key, visited in spelling order. This
// distinguishes an extra visit to a key from a trace that simply passed nearby.
fn fit(keys: &[Point], word: &Word, path: &[Point; 64], total: f32) -> PathFit {
    let letters = &word.letters[..word.count as usize];
    let mut costs = [0.; 64];
    let mut ideal = 0.;
    for (i, &letter) in letters.iter().enumerate() {
        let center = keys[letter as usize];
        if i > 0 {
            ideal += center.sq(keys[letters[i - 1] as usize]).sqrt();
        }
        let mut best_so_far = f32::INFINITY;
        for (j, value) in costs.iter_mut().enumerate() {
            best_so_far = best_so_far.min(*value);
            let error = path[j].sq(center);
            *value = best_so_far + error;
        }
    }
    let ordered = costs.into_iter().fold(f32::INFINITY, f32::min) / letters.len() as f32;
    PathFit {
        ordered_error: ordered,
        length_error: (ideal / total).ln().abs(),
        start_error: keys[letters[0] as usize].sq(path[0]),
        end_error: keys[*letters.last().unwrap() as usize].sq(path[63]),
    }
}

pub(super) fn compare(
    keys: &[Point],
    stroke: &Stroke,
    previous: &str,
    current: &[Match],
) -> Option<(&'static str, Features)> {
    let leader = current.first()?.word;
    if leader.text.len() < 7 {
        return None;
    }
    let basic = rank::<24>(keys, stroke, previous);
    let alternative = basic.first()?.word;
    if leader.text == alternative.text || alternative.text.len() < 7 {
        return None;
    }
    let path = resample::<64>(&stroke.pts, &stroke.arc);
    let a = fit(keys, leader, &path, stroke.total);
    let b = fit(keys, alternative, &path, stroke.total);
    Some((
        alternative.text,
        [
            margin(current),
            margin(&basic),
            alternative.prior - leader.prior,
            a.ordered_error,
            b.ordered_error,
            b.length_error - a.length_error,
            b.start_error - a.start_error,
            b.end_error - a.end_error,
            alternative.count as f32 - leader.count as f32,
        ],
    ))
}

pub(super) fn prefer_alternative(features: &Features) -> bool {
    WEIGHTS[0]
        + features
            .iter()
            .zip(&WEIGHTS[1..])
            .map(|(x, w)| x * w)
            .sum::<f32>()
        > 0.
}

// The training tool requests competing words and numeric features from the same
// code used by the extension. The shipping build does not export this interface.
#[cfg(feature = "glide-training")]
#[no_mangle]
unsafe extern "C" fn mb_glide_training_pair(
    keys: *const Point,
    samples: *const super::MBGlideSample,
    count: usize,
    out: *mut f32,
    names: *mut std::ffi::c_char,
) -> i32 {
    if keys.is_null()
        || samples.is_null()
        || out.is_null()
        || names.is_null()
        || !(2..=256).contains(&count)
    {
        return -1;
    }
    let keys = unsafe { std::slice::from_raw_parts(keys, 26) };
    let trace = unsafe { std::slice::from_raw_parts(samples, count) };
    let Some(stroke) = super::prepare(keys, trace) else {
        return 0;
    };
    let current = rank::<32>(keys, &stroke, "");
    let Some((alternate, features)) = compare(keys, &stroke, "", &current) else {
        return 0;
    };
    let names_out = format!("{}\t{}\0", current[0].word.text, alternate);
    // Caller supplies space for 64 floats and 64 bytes. Words are at most 24 bytes each.
    unsafe {
        std::ptr::copy_nonoverlapping(features.as_ptr(), out, COUNT);
        std::ptr::copy_nonoverlapping(names_out.as_ptr(), names.cast(), names_out.len());
    }
    COUNT as i32
}
