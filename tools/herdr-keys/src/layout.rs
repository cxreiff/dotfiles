//! Spatial pane selection when navigation leaves one tab and enters another.

use crate::Dir;
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn from_json(value: &Value) -> Option<Rect> {
        Some(Rect {
            x: value["x"].as_f64()?,
            y: value["y"].as_f64()?,
            w: value["width"].as_f64()?,
            h: value["height"].as_f64()?,
        })
    }
}

/// The pane entered when leaving `source` (inside `source_area`) through its
/// `dir` edge into a tab laid out as `panes` (inside `target_area`): a pane on
/// the target's opposite edge, aligned with the source's center. Tabs can be
/// sized by different clients, so alignment is proportional. When the center
/// sits exactly on a seam, `preferred` (the tab's remembered pane) wins.
pub fn entry_pane<'a>(
    dir: Dir,
    source_area: Rect,
    source: Rect,
    target_area: Rect,
    panes: &'a [(String, Rect)],
    preferred: Option<&str>,
) -> Option<&'a str> {
    let horizontal = matches!(dir, Dir::Left | Dir::Right);
    // Edge coordinate of each pane on the side we enter through.
    let edge = |r: &Rect| match dir {
        Dir::Right => r.x,
        Dir::Left => -(r.x + r.w),
        Dir::Down => r.y,
        Dir::Up => -(r.y + r.h),
    };
    let entry = panes.iter().map(|(_, r)| edge(r)).reduce(f64::min)?;

    // Perpendicular span of a rect, and the source center mapped into the target.
    let span = |r: &Rect| {
        if horizontal {
            (r.y, r.y + r.h)
        } else {
            (r.x, r.x + r.w)
        }
    };
    let (s0, s1) = span(&source);
    let (a0, a1) = span(&source_area);
    let (t0, t1) = span(&target_area);
    let fraction = if a1 > a0 {
        ((s0 + s1) / 2.0 - a0) / (a1 - a0)
    } else {
        0.5
    };
    let point = t0 + fraction * (t1 - t0);

    let distance = |r: &Rect| {
        let (lo, hi) = span(r);
        (lo - point).max(point - hi).max(0.0)
    };
    panes
        .iter()
        .filter(|(_, r)| (edge(r) - entry).abs() < 0.5)
        .min_by(|(a_id, a), (b_id, b)| {
            let rank = |id: &String, r: &Rect| (distance(r), Some(id.as_str()) != preferred);
            let ((da, pa), (db, pb)) = (rank(a_id, a), rank(b_id, b));
            da.total_cmp(&db).then(pa.cmp(&pb))
        })
        .map(|(id, _)| id.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }

    // ┌────┬────┐
    // │ a  │ b  │
    // │    ├────┤
    // │    │ c  │
    // └────┴────┘
    fn three() -> Vec<(String, Rect)> {
        vec![
            ("a".into(), r(0., 0., 50., 40.)),
            ("b".into(), r(50., 0., 50., 20.)),
            ("c".into(), r(50., 20., 50., 20.)),
        ]
    }
    const AREA: Rect = Rect {
        x: 0.,
        y: 0.,
        w: 100.,
        h: 40.,
    };

    #[test]
    fn entering_from_the_left_lands_on_the_left_column() {
        let source = r(50., 20., 50., 20.);
        assert_eq!(
            entry_pane(Dir::Right, AREA, source, AREA, &three(), None),
            Some("a")
        );
    }

    #[test]
    fn entering_from_the_right_keeps_the_row() {
        let top = r(0., 0., 100., 10.);
        let bottom = r(0., 30., 100., 10.);
        assert_eq!(
            entry_pane(Dir::Left, AREA, top, AREA, &three(), None),
            Some("b")
        );
        assert_eq!(
            entry_pane(Dir::Left, AREA, bottom, AREA, &three(), None),
            Some("c")
        );
    }

    #[test]
    fn vertical_entry_keeps_the_column() {
        let left = r(0., 0., 30., 40.);
        let right = r(70., 0., 30., 40.);
        // Moving up enters through the bottom edge: a and c touch it.
        assert_eq!(
            entry_pane(Dir::Up, AREA, left, AREA, &three(), None),
            Some("a")
        );
        assert_eq!(
            entry_pane(Dir::Up, AREA, right, AREA, &three(), None),
            Some("c")
        );
        // Moving down enters through the top edge: a and b touch it.
        assert_eq!(
            entry_pane(Dir::Down, AREA, right, AREA, &three(), None),
            Some("b")
        );
    }

    #[test]
    fn alignment_is_proportional_across_differently_sized_tabs() {
        let small = r(0., 0., 100., 20.);
        let source = r(0., 15., 100., 5.); // bottom quarter of a 20-row tab
        assert_eq!(
            entry_pane(Dir::Left, small, source, AREA, &three(), None),
            Some("c")
        );
    }

    #[test]
    fn seam_ties_go_to_the_remembered_pane() {
        let source = r(0., 0., 100., 40.); // center y = 20, the b/c seam
        let panes = three();
        assert_eq!(
            entry_pane(Dir::Left, AREA, source, AREA, &panes, Some("c")),
            Some("c")
        );
        assert_eq!(
            entry_pane(Dir::Left, AREA, source, AREA, &panes, Some("b")),
            Some("b")
        );
        // Remembered pane off the entry edge or off the seam does not override.
        assert_eq!(
            entry_pane(Dir::Left, AREA, source, AREA, &panes, Some("a")),
            Some("b")
        );
        let top = r(0., 0., 100., 10.);
        assert_eq!(
            entry_pane(Dir::Left, AREA, top, AREA, &panes, Some("c")),
            Some("b")
        );
    }

    #[test]
    fn single_pane() {
        let one = vec![("only".into(), AREA)];
        assert_eq!(
            entry_pane(Dir::Down, AREA, AREA, AREA, &one, None),
            Some("only")
        );
        assert_eq!(entry_pane(Dir::Down, AREA, AREA, AREA, &[], None), None);
    }
}
