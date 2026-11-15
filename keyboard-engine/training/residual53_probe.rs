// Include the production candidate extractor, so fitting and shipping use
// identical lexicon, edit neighborhoods, casing guards and context counts.
#[path = "../src/textspell30.rs"]
mod textspell30;
use std::io::{self, BufRead, BufWriter, Write};
fn main() {
    let mut out = BufWriter::new(io::stdout().lock());
    for line in io::stdin().lock().lines().map_while(Result::ok) {
        let mut row = line.split('\t');
        let (left, typed, right) = (
            row.next().unwrap(),
            row.next().unwrap(),
            row.next().unwrap(),
        );
        let mut candidates = textspell30::residual53::candidates(left, typed, right);
        candidates.sort_unstable_by(|a, b| a.0.cmp(&b.0));
        out.write_all(&(candidates.len() as u16).to_le_bytes())
            .unwrap();
        for (word, features) in candidates {
            out.write_all(&[word.len() as u8]).unwrap();
            out.write_all(word.as_bytes()).unwrap();
            for f in features {
                out.write_all(&f.to_le_bytes()).unwrap();
            }
        }
    }
}
