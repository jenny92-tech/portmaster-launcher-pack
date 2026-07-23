use std::cmp::Ordering;
use std::io;
use std::path::{Path, PathBuf};

pub fn latest_love(root: &Path) -> io::Result<PathBuf> {
    let mut candidates = Vec::new();
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name.starts_with("love_") {
            continue;
        }
        let path = entry.path().join("love.txt");
        if path.is_file() {
            candidates.push((name.to_owned(), path));
        }
    }
    candidates
        .into_iter()
        .max_by(|left, right| natural_cmp(&left.0, &right.0))
        .map(|(_, path)| path)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no LOVE runtime was found"))
}

fn natural_cmp(left: &str, right: &str) -> Ordering {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let (mut l, mut r) = (0, 0);
    while l < left.len() && r < right.len() {
        if left[l].is_ascii_digit() && right[r].is_ascii_digit() {
            let l_end = digit_end(left, l);
            let r_end = digit_end(right, r);
            let l_digits = trim_zeroes(&left[l..l_end]);
            let r_digits = trim_zeroes(&right[r..r_end]);
            let ordering = l_digits
                .len()
                .cmp(&r_digits.len())
                .then_with(|| l_digits.cmp(r_digits))
                .then_with(|| (l_end - l).cmp(&(r_end - r)));
            if ordering != Ordering::Equal {
                return ordering;
            }
            l = l_end;
            r = r_end;
        } else {
            let ordering = left[l].cmp(&right[r]);
            if ordering != Ordering::Equal {
                return ordering;
            }
            l += 1;
            r += 1;
        }
    }
    left.len().cmp(&right.len())
}

fn digit_end(value: &[u8], mut index: usize) -> usize {
    while index < value.len() && value[index].is_ascii_digit() {
        index += 1;
    }
    index
}

fn trim_zeroes(value: &[u8]) -> &[u8] {
    let first = value
        .iter()
        .position(|byte| *byte != b'0')
        .unwrap_or(value.len().saturating_sub(1));
    &value[first..]
}
