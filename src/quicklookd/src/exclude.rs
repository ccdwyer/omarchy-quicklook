use std::path::{Component, Path};

const SKIP_DIR_NAMES: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".password-store",
    "node_modules",
    "target",
    ".git",
    ".hg",
    ".svn",
    ".bzr",
    "__pycache__",
    ".venv",
    "venv",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".cargo",
    ".rustup",
    ".npm",
    ".cache",
    ".Trash",
    ".local",
    "keyrings",
    "kwalletd",
    "Keychains",
];

const SKIP_PATH_PARTS: &[&str] = &[
    "/.ssh/",
    "/.gnupg/",
    "/.password-store/",
    "/.local/share/keyrings/",
    "/.local/share/kwalletd/",
    "/Library/Keychains/",
];

pub fn skip_dir_name(name: &str, extra: &[String]) -> bool {
    if SKIP_DIR_NAMES.iter().any(|n| *n == name) {
        return true;
    }
    extra.iter().any(|e| e == name)
}

pub fn skip_hidden_dir(name: &str) -> bool {
    name.starts_with('.') && name != "." && name != ".."
}

pub fn path_is_secret(path: &Path) -> bool {
    let s = path.to_string_lossy();
    if SKIP_PATH_PARTS.iter().any(|p| s.contains(p)) {
        return true;
    }
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if name == ".env" || name.starts_with(".env.") || name.ends_with(".env") {
            return true;
        }
        if name == "id_rsa" || name == "id_ed25519" || name.starts_with("id_rsa.") {
            return true;
        }
    }
    false
}

pub fn should_skip_dir(path: &Path, extra: &[String], root: &Path) -> bool {
    if path == root {
        return false;
    }
    if path_is_secret(path) {
        return true;
    }
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if skip_dir_name(name, extra) {
            return true;
        }
        if skip_hidden_dir(name) {
            return true;
        }
    }
    false
}

pub fn should_skip_file(path: &Path) -> bool {
    path_is_secret(path)
}

pub fn under_root(path: &Path, roots: &[std::path::PathBuf]) -> bool {
    roots.iter().any(|r| path.starts_with(r))
}

pub fn normalize_components(path: &Path) -> bool {
    !path.components().any(|c| matches!(c, Component::ParentDir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn excludes_secrets_and_heavy_dirs() {
        assert!(should_skip_dir(
            Path::new("/home/x/.ssh"),
            &[],
            Path::new("/home/x")
        ));
        assert!(should_skip_dir(
            Path::new("/home/x/proj/node_modules"),
            &[],
            Path::new("/home/x")
        ));
        assert!(should_skip_dir(
            Path::new("/home/x/proj/target"),
            &[],
            Path::new("/home/x")
        ));
        assert!(should_skip_dir(
            Path::new("/home/x/proj/.git"),
            &[],
            Path::new("/home/x")
        ));
        assert!(should_skip_file(Path::new("/home/x/proj/.env")));
        assert!(!should_skip_dir(
            Path::new("/home/x/Documents"),
            &[],
            Path::new("/home/x")
        ));
        assert!(!should_skip_dir(
            Path::new("/home/x"),
            &[],
            Path::new("/home/x")
        ));
    }

    #[test]
    fn extra_exclude_names() {
        let extra = vec!["Secrets".into()];
        assert!(skip_dir_name("Secrets", &extra));
        assert!(!skip_dir_name("Documents", &extra));
    }

    #[test]
    fn hidden_dirs_skipped_except_root() {
        assert!(should_skip_dir(
            &PathBuf::from("/home/x/.config"),
            &[],
            &PathBuf::from("/home/x")
        ));
        assert!(!should_skip_dir(
            &PathBuf::from("/home/x/.config"),
            &[],
            &PathBuf::from("/home/x/.config")
        ));
    }
}
