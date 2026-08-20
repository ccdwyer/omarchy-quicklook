use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Image,
    Pdf,
    Csv,
    Code,
    Dir,
    Video,
    Hex,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Image => "image",
            Kind::Pdf => "pdf",
            Kind::Csv => "csv",
            Kind::Code => "code",
            Kind::Dir => "dir",
            Kind::Video => "video",
            Kind::Hex => "hex",
        }
    }
}

pub fn ext_of(path: &Path) -> String {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match name.as_str() {
        "makefile" | "dockerfile" => return name,
        "cmakelists.txt" => return "cmake".into(),
        _ => {}
    }
    path.extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default()
}

pub fn kind_of(path: &Path, is_dir: bool) -> Kind {
    if is_dir {
        return Kind::Dir;
    }
    match ext_of(path).as_str() {
        "png" | "jpg" | "jpeg" | "webp" | "svg" | "gif" | "bmp" | "ico" | "tif" | "tiff" => {
            Kind::Image
        }
        "pdf" => Kind::Pdf,
        "csv" | "tsv" => Kind::Csv,
        "mp4" | "webm" | "mkv" | "mov" | "avi" | "m4v" => Kind::Video,
        "rs" | "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" | "py" | "go" | "c" | "h" | "cc"
        | "cpp" | "hpp" | "hh" | "java" | "kt" | "kts" | "rb" | "php" | "sh" | "bash" | "zsh"
        | "fish" | "lua" | "qml" | "json" | "yaml" | "yml" | "toml" | "md" | "html" | "htm"
        | "css" | "scss" | "xml" | "sql" | "swift" | "cs" | "scala" | "ex" | "exs" | "hs"
        | "elm" | "zig" | "nim" | "r" | "pl" | "pm" | "vim" | "dockerfile" | "makefile"
        | "mk" | "txt" | "conf" | "ini" | "log" | "lock" | "gradle" | "cmake" | "s" | "asm"
        | "proto" | "graphql" | "vue" | "svelte" | "nix" | "tf" | "hcl" => Kind::Code,
        _ => Kind::Hex,
    }
}

pub fn is_animated(path: &Path) -> bool {
    ext_of(path) == "gif"
}

pub fn pass_through_image(path: &Path) -> bool {
    matches!(ext_of(path).as_str(), "svg" | "gif")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn detects_common_kinds() {
        assert_eq!(kind_of(&PathBuf::from("a/invoice.pdf"), false), Kind::Pdf);
        assert_eq!(kind_of(&PathBuf::from("a/photo.png"), false), Kind::Image);
        assert_eq!(kind_of(&PathBuf::from("a/sales.csv"), false), Kind::Csv);
        assert_eq!(kind_of(&PathBuf::from("a/themed.rs"), false), Kind::Code);
        assert_eq!(kind_of(&PathBuf::from("a/README.md"), false), Kind::Code);
        assert_eq!(kind_of(&PathBuf::from("a/clip.webm"), false), Kind::Video);
        assert_eq!(kind_of(&PathBuf::from("a/blob.bin"), false), Kind::Hex);
        assert_eq!(kind_of(&PathBuf::from("a/src"), true), Kind::Dir);
        assert_eq!(kind_of(&PathBuf::from("Makefile"), false), Kind::Code);
    }
}
