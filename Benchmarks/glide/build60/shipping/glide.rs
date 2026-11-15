//! Offline shape matching in units of one key pitch, using the caller's geometry.
use crate::{history, pair_count, WORDS};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct MBKeyCenter {
    pub x: f32,
    pub y: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MBGlideSample {
    pub x: f32,
    pub y: f32,
    pub seconds: f32,
}

type Point = MBKeyCenter;
impl Point {
    fn sq(self, b: Self) -> f32 {
        (self.x - b.x).powi(2) + (self.y - b.y).powi(2)
    }
    fn interpolate(self, b: Self, t: f32) -> Self {
        Self {
            x: self.x + t * (b.x - self.x),
            y: self.y + t * (b.y - self.y),
        }
    }
    fn valid(self) -> bool {
        self.x.abs() < 1024. && self.y.abs() < 1024.
    }
}

struct Word {
    text: &'static str,
    letters: [u8; 24],
    count: u8,
    prior: f32,
    base_prior: Option<f32>,
}

const BINS: usize = 26 * 26;
static LEXICON: LazyLock<[Vec<Word>; BINS]> = LazyLock::new(|| {
    let mut bins: [Vec<Word>; BINS] = std::array::from_fn(|_| Vec::new());
    fn frequencies(table: &'static str) -> impl Iterator<Item = (&'static str, f32)> {
        table.lines().filter_map(|row| {
            let (word, frequency) = row.split_once('\t')?;
            Some((word, frequency.parse::<f32>().ok()? / 100.))
        })
    }
    let mut base: HashMap<_, _> = frequencies(include_str!("../model/glide-words.tsv")).collect();
    let mut all = base.clone();
    all.extend(frequencies(include_str!("../model/glide-long.tsv")));
    for (&word, &count) in WORDS.iter() {
        let prior = 2. + (count as f32).log10();
        base.entry(word).or_insert(prior);
        all.entry(word).or_insert(prior);
    }
    for (text, prior) in all {
        if !(2..=24).contains(&text.len())
            || !text.bytes().all(|b| b.is_ascii_lowercase() || b == b'\'')
        {
            continue;
        }
        let mut letters = [0; 24];
        let mut count = 0;
        for byte in text.bytes().filter(u8::is_ascii_lowercase) {
            let letter = byte - b'a';
            if count == 0 || letters[count - 1] != letter {
                letters[count] = letter;
                count += 1;
            }
        }
        if count >= 2 {
            let bin = 26 * letters[0] as usize + letters[count - 1] as usize;
            bins[bin].push(Word {
                text,
                letters,
                count: count as u8,
                prior,
                base_prior: base.get(text).copied(),
            });
        }
    }
    bins
});

type Shape<const N: usize> = [Point; N];

fn resample<const N: usize>(points: &[Point], cumulative: &[f32]) -> Shape<N> {
    let total = cumulative[cumulative.len() - 1];
    let mut j = 1;
    std::array::from_fn(|i| {
        let d = total * i as f32 / (N - 1) as f32;
        while j + 1 < points.len() && cumulative[j] < d {
            j += 1;
        }
        let t = (d - cumulative[j - 1]) / (cumulative[j] - cumulative[j - 1]).max(1e-6);
        points[j - 1].interpolate(points[j], t.clamp(0., 1.))
    })
}

fn direction<const N: usize>(shape: &Shape<N>) -> Shape<N> {
    std::array::from_fn(|i| {
        let a = shape[i.saturating_sub(1)];
        let b = shape[(i + 1).min(N - 1)];
        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let norm = dx.hypot(dy).max(0.18);
        Point {
            x: dx / norm,
            y: dy / norm,
        }
    })
}

fn aligned_cost<const N: usize>(
    a: &Shape<N>,
    direction_a: &Shape<N>,
    b: &Shape<N>,
    turns: bool,
) -> f32 {
    let band = if N == 24 { 4 } else { 6 };
    let direction_b = if turns { Some(direction(b)) } else { None };
    // Banded dynamic time warping lets corners fall a little earlier or later.
    let mut prev = [f32::INFINITY; 33];
    prev[0] = 0.;
    for (i, point) in a.iter().enumerate() {
        let mut now = [f32::INFINITY; 33];
        for j in i.saturating_sub(band)..=(i + band).min(N - 1) {
            let angle = direction_b
                .as_ref()
                .map_or(0., |db| 0.36 * direction_a[i].sq(db[j]));
            now[j + 1] = point.sq(b[j]).min(16.)
                + angle
                + prev[j].min((prev[j + 1] + 0.06).min(now[j] + 0.06));
        }
        prev = now;
    }
    prev[N] / N as f32
}

struct Stroke {
    pts: Vec<Point>,
    arc: Vec<f32>,
    total: f32,
}

fn prepare(keys: &[Point], trace: &[MBGlideSample]) -> Option<Stroke> {
    if keys.len() != 26 || !(2..=256).contains(&trace.len()) || !keys.iter().all(|p| p.valid()) {
        return None;
    }
    let mut pts = Vec::with_capacity(trace.len());
    let mut arc = Vec::with_capacity(trace.len());
    let mut total = 0.;
    let mut last_time = -1.;
    for (i, s) in trace.iter().enumerate() {
        let p = Point { x: s.x, y: s.y };
        if !p.valid() || !s.seconds.is_finite() || s.seconds < 0. || s.seconds < last_time {
            return None;
        }
        let dt = s.seconds - last_time;
        last_time = s.seconds;
        if let Some(&last) = pts.last() {
            let distance = p.sq(last).sqrt();
            // Ignore stationary touch jitter, keeping both endpoints.
            if distance < 0.001 || (i + 1 < trace.len() && dt < 0.04 && distance < 0.06) {
                continue;
            }
            total += distance;
        }
        pts.push(p);
        arc.push(total);
    }
    if total < 1.6 || pts.len() < 2 {
        return None;
    }
    Some(Stroke { pts, arc, total })
}

#[derive(Clone, Copy)]
struct Match {
    word: &'static Word,
    cost: f32,
}

fn rank<const N: usize>(keys: &[Point], stroke: &Stroke, previous: &str) -> Vec<Match> {
    let total = stroke.total;
    let gesture = resample::<N>(&stroke.pts, &stroke.arc);
    let turns = N == 32 && total >= 8.;
    let gesture_direction = if turns {
        direction(&gesture)
    } else {
        [Point::default(); N]
    };
    let endpoint_limit = if turns { 2.25 } else { 1.55 };
    let geometry_limit = if turns { 1.52 } else { 1.10 };
    let start = gesture[0];
    let end = gesture[N - 1];
    // Keep only the best coarse matches while scanning. This bounds temporary
    // storage even when the two endpoint keys cover thousands of words.
    const SHORTLIST: usize = 48;
    const BATCH: usize = 256;
    let mut pool = Vec::with_capacity(BATCH);
    let cmp = |a: &(f32, f32, Shape<N>, &Word), b: &(f32, f32, Shape<N>, &Word)| {
        a.0.total_cmp(&b.0).then_with(|| a.3.text.cmp(b.3.text))
    };
    // Screen endpoint and length first. Only the best coarse matches need DTW.
    for (first, first_key) in keys.iter().enumerate() {
        let start_error = start.sq(*first_key);
        if start_error > endpoint_limit {
            continue;
        }
        for (last, last_key) in keys.iter().enumerate() {
            let end_error = end.sq(*last_key);
            if end_error > endpoint_limit {
                continue;
            }
            for w in &LEXICON[first * 26 + last] {
                let prior = if N == 24 {
                    let Some(value) = w.base_prior else {
                        continue;
                    };
                    value
                } else {
                    w.prior
                };
                let mut cumulative = [0.; 24];
                let mut centers = [Point::default(); 24];
                let n = w.count as usize;
                for (i, &letter) in w.letters[..n].iter().enumerate() {
                    centers[i] = keys[letter as usize];
                    if i > 0 {
                        cumulative[i] = cumulative[i - 1] + centers[i].sq(centers[i - 1]).sqrt();
                    }
                }
                let length = cumulative[n - 1];
                if length < 0.1 || length > 2.1 * total + 1. || total > 2.0 * length + 1. {
                    continue;
                }
                let mut template = resample(&centers[..n], &cumulative[..n]);
                if turns {
                    // A finger rounds the sharpest corners between letter centers.
                    let raw = template;
                    for i in 1..N - 1 {
                        let middle = raw[i - 1].interpolate(raw[i + 1], 0.5);
                        template[i] = raw[i].interpolate(middle, 0.42);
                    }
                }
                let offset = gesture
                    .iter()
                    .zip(template)
                    .map(|(p, q)| p.sq(q).min(16.))
                    .sum::<f32>()
                    / N as f32;
                let bias = 0.28 * (start_error + end_error) + 0.45 * (length / total).ln().abs()
                    - 0.08 * (prior - 3.);
                pool.push((offset + bias, bias, template, w));
                if pool.len() == BATCH {
                    pool.select_nth_unstable_by(SHORTLIST, cmp);
                    pool.truncate(SHORTLIST);
                }
            }
        }
    }
    if pool.len() > SHORTLIST {
        pool.select_nth_unstable_by(SHORTLIST, cmp);
        pool.truncate(SHORTLIST);
    }
    let mut ranked = Vec::new();
    for (_, bias, shape, w) in pool {
        let geometry = aligned_cost(&gesture, &gesture_direction, &shape, turns);
        if geometry > geometry_limit {
            continue;
        }
        let contextual = if previous.is_empty() {
            0.
        } else {
            (pair_count(previous, w.text) as f32).ln_1p().min(6.)
        };
        ranked.push(Match {
            word: w,
            cost: geometry + bias - 0.047 * contextual,
        });
    }
    ranked.sort_unstable_by(|a, b| {
        a.cost
            .total_cmp(&b.cost)
            .then_with(|| a.word.text.cmp(b.word.text))
    });
    ranked
}

#[path = "glide_choice.rs"]
mod choice;

fn decode(keys: &[Point], trace: &[MBGlideSample], context: &str) -> Vec<&'static str> {
    let Some(stroke) = prepare(keys, trace) else {
        return vec![];
    };
    let (_, previous) = history(context);
    let current = rank::<32>(keys, &stroke, &previous);
    let mut words: Vec<_> = current.iter().take(3).map(|m| m.word.text).collect();
    if let Some((alternative, features)) = choice::compare(keys, &stroke, &previous, &current) {
        if choice::prefer_alternative(&features) {
            words.retain(|&word| word != alternative);
            words.insert(0, alternative);
            words.truncate(3);
        }
    }
    words
}

/// Returns up to three tab-separated alternatives. All coordinates are measured
/// in key pitches. No geometry, text, or gesture is retained between calls.
/// # Safety
/// keys and samples must point to arrays of their specified lengths, context to
/// a NUL-terminated string, and out to capacity bytes of writable memory.
#[no_mangle]
pub unsafe extern "C" fn mb_glide_v1(
    keys: *const MBKeyCenter,
    key_count: usize,
    samples: *const MBGlideSample,
    count: usize,
    context: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if keys.is_null()
        || samples.is_null()
        || context.is_null()
        || out.is_null()
        || capacity == 0
        || key_count != 26
        || !(2..=256).contains(&count)
    {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    let Ok(left) = unsafe { CStr::from_ptr(context) }.to_str() else {
        return -1;
    };
    if left.len() > 2048 {
        return -1;
    }
    let words = decode(
        unsafe { std::slice::from_raw_parts(keys, key_count) },
        unsafe { std::slice::from_raw_parts(samples, count) },
        left,
    );
    let text = words.join("\t");
    if text.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(text.as_ptr(), out.cast(), text.len());
        *out.add(text.len()) = 0;
    }
    words.len() as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(gap: f32) -> [Point; 26] {
        let mut keys = [Point::default(); 26];
        for (y, row) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].iter().enumerate() {
            for (i, letter) in row.bytes().enumerate() {
                let x = i as f32 + [0.0, 0.5, 1.5][y];
                keys[(letter - b'a') as usize] = Point {
                    x: if x < 5.0 { x } else { x + gap },
                    y: y as f32,
                };
            }
        }
        keys
    }

    fn trace(keys: &[Point], word: &str) -> Vec<MBGlideSample> {
        word.bytes()
            .enumerate()
            .map(|(i, letter)| {
                let point = keys[(letter - b'a') as usize];
                MBGlideSample {
                    x: point.x,
                    y: point.y,
                    seconds: i as f32 / 10.0,
                }
            })
            .collect()
    }

    #[test]
    fn ranks_multi_turn_paths_and_repeated_letters_on_joined_and_split_layouts() {
        for gap in [0.0, 3.0] {
            let keys = layout(gap);
            for word in [
                "hello",
                "coffee",
                "morning",
                "autobiographies",
                "doorkeeper",
            ] {
                assert_eq!(decode(&keys, &trace(&keys, word), "").first(), Some(&word));
            }
            let options = decode(&keys, &trace(&keys, "to"), "");
            assert_eq!(options.first(), Some(&"to"));
            assert!(options.contains(&"too"));
        }
    }

    #[test]
    fn declines_taps_and_malformed_traces() {
        let keys = layout(0.0);
        assert!(decode(&keys, &trace(&keys, "qq"), "").is_empty());
        assert!(decode(&keys, &trace(&keys, "qw"), "").is_empty());
        let mut path = trace(&keys, "home");
        path[2].seconds = 0.;
        assert!(decode(&keys, &path, "").is_empty());
        path[2].x = f32::NAN;
        path[2].seconds = 0.2;
        assert!(decode(&keys, &path, "").is_empty());
    }

    #[test]
    fn ffi_declines_invalid_lengths_and_short_output_buffers() {
        let keys = layout(0.0);
        let path = trace(&keys, "good");
        let mut output = [42; 2];
        for key_count in [25, 26] {
            let result = unsafe {
                mb_glide_v1(
                    keys.as_ptr(),
                    key_count,
                    path.as_ptr(),
                    path.len(),
                    c"".as_ptr(),
                    output.as_mut_ptr(),
                    output.len(),
                )
            };
            assert_eq!(result, -1);
        }
        assert_eq!(output[0], 0);
    }
}
