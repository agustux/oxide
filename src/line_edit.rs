//! A one-line text field with a cursor, for the small inputs that live in
//! footers and overlays. Owns the editing keys so each input doesn't have to.

use gpui::Keystroke;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct LineEdit {
    pub text: String,
    /// In chars, not bytes.
    cursor: usize,
}

impl LineEdit {
    /// Start with `text` and the cursor at its end.
    pub fn new(text: String) -> Self {
        let cursor = text.chars().count();
        Self { text, cursor }
    }

    /// Start with `text` and the cursor at its start — for prefilled paths
    /// that most often get a directory typed in front.
    pub fn at_start(text: String) -> Self {
        Self { text, cursor: 0 }
    }

    fn byte(&self, at: usize) -> usize {
        self.text
            .char_indices()
            .nth(at)
            .map_or(self.text.len(), |(b, _)| b)
    }

    /// The far edge of the word before or after the cursor: across any
    /// separators first, then across the word. Punctuation separates, so a
    /// path moves a component at a time.
    fn word_edge(&self, forward: bool) -> usize {
        let chars: Vec<char> = self.text.chars().collect();
        let mut at = self.cursor;
        for in_word in [false, true] {
            loop {
                let next = if forward { Some(at) } else { at.checked_sub(1) };
                match next.and_then(|i| chars.get(i)) {
                    Some(c) if c.is_alphanumeric() == in_word => {
                        at = if forward { at + 1 } else { at - 1 }
                    }
                    _ => break,
                }
            }
        }
        at
    }

    /// Remove the chars in `from..to` and leave the cursor where they were.
    fn delete(&mut self, from: usize, to: usize) {
        let (b, e) = (self.byte(from), self.byte(to));
        self.text.replace_range(b..e, "");
        self.cursor = from;
    }

    /// Apply an editing key. Returns whether it was one; anything else
    /// (enter, escape) is the caller's.
    pub fn handle(&mut self, ks: &Keystroke) -> bool {
        let m = ks.modifiers;
        let len = self.text.chars().count();
        // Word-wise: option on macOS, control everywhere else.
        let word = m.alt || (m.control && !cfg!(target_os = "macos"));
        match ks.key.as_str() {
            "left" if m.platform => self.cursor = 0,
            "right" if m.platform => self.cursor = len,
            "left" if word => self.cursor = self.word_edge(false),
            "right" if word => self.cursor = self.word_edge(true),
            "left" => self.cursor = self.cursor.saturating_sub(1),
            "right" => self.cursor = (self.cursor + 1).min(len),
            "home" => self.cursor = 0,
            "end" => self.cursor = len,
            "a" if m.control => self.cursor = 0,
            "e" if m.control => self.cursor = len,
            "backspace" if m.platform => self.delete(0, self.cursor),
            "backspace" if word => self.delete(self.word_edge(false), self.cursor),
            "backspace" => self.delete(self.cursor.saturating_sub(1), self.cursor),
            "delete" if word => self.delete(self.cursor, self.word_edge(true)),
            "delete" => self.delete(self.cursor, (self.cursor + 1).min(len)),
            _ => {
                let plain = !m.platform && !m.control && !m.function;
                let Some(c) = ks.key_char.as_deref().filter(|_| plain) else {
                    return false;
                };
                let b = self.byte(self.cursor);
                self.text.insert_str(b, c);
                self.cursor += c.chars().count();
            }
        }
        true
    }

    /// The text either side of the cursor, so a caller can draw a real
    /// caret between them (a glyph would take a whole monospace cell).
    pub fn split(&self) -> (&str, &str) {
        self.text.split_at(self.byte(self.cursor))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(s: &str) -> Keystroke {
        let mut ks = Keystroke::parse(s).unwrap();
        if ks.key.chars().count() == 1 && !ks.modifiers.control && !ks.modifiers.platform {
            ks.key_char = Some(ks.key.clone());
        }
        ks
    }

    #[test]
    fn cursor_moves_and_edits_in_the_middle() {
        let mut e = LineEdit::new("tést".into());
        assert_eq!(e.split(), ("tést", ""));
        for _ in 0..4 {
            e.handle(&key("left"));
        }
        assert!(e.handle(&key("x")));
        assert_eq!(e.split(), ("x", "tést"));
        e.handle(&key("cmd-right"));
        e.handle(&key("backspace"));
        e.handle(&key("ctrl-a"));
        e.handle(&key("delete"));
        assert_eq!(e.text, "tés");
        assert!(!e.handle(&key("enter")));
    }

    #[test]
    fn option_moves_and_deletes_by_word() {
        let mut e = LineEdit::new("src/té st.rs".into());
        e.handle(&key("alt-left"));
        assert_eq!(e.split(), ("src/té st.", "rs"));
        e.handle(&key("alt-backspace"));
        assert_eq!(e.split(), ("src/té ", "rs"), "separators go with the word");
        e.handle(&key("alt-left"));
        e.handle(&key("alt-left"));
        assert_eq!(e.split(), ("", "src/té rs"));
        e.handle(&key("alt-right"));
        e.handle(&key("alt-delete"));
        assert_eq!(e.split(), ("src", " rs"));
        e.handle(&key("cmd-backspace"));
        assert_eq!(e.text, " rs");
        // Nothing to cross at either end.
        e.handle(&key("alt-backspace"));
        e.handle(&key("cmd-right"));
        e.handle(&key("alt-delete"));
        assert_eq!(e.text, " rs");
    }
}
