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

/// Same ancestor-aware policy as the indexed walk: drop secrets, off-root
/// hits, and any path whose ancestor (except an explicit root) is hidden or heavy.
pub fn should_skip_located(path: &Path, extra: &[String], roots: &[std::path::PathBuf]) -> bool {
    if !normalize_components(path) {
        return true;
    }
    if path_is_secret(path) {
        return true;
    }
    if !roots.is_empty() && !under_root(path, roots) {
        return true;
    }
    let mut ancestor = path.parent();
    while let Some(dir) = ancestor {
        if roots.iter().any(|r| dir == r.as_path()) {
            break;
        }
        if dir.as_os_str().is_empty() || dir == Path::new("/") {
            break;
        }
        if should_skip_dir(dir, extra, Path::new("/")) {
            return true;
        }
        let next = dir.parent();
        if next == Some(dir) {
            break;
        }
        ancestor = next;
    }
    false
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

    #[test]
    fn located_skips_hidden_and_heavy_ancestors() {
        let home = PathBuf::from("/home/x");
        assert!(should_skip_located(
            Path::new("/home/x/.cache/invoice.pdf"),
            &[],
            &[home.clone()]
        ));
        assert!(should_skip_located(
            Path::new("/home/x/proj/node_modules/pkg/index.js"),
            &[],
            &[home.clone()]
        ));
        assert!(should_skip_located(
            Path::new("/home/x/.hidden/invoice-hid.txt"),
            &[],
            &[home.clone()]
        ));
        assert!(!should_skip_located(
            Path::new("/home/x/Documents/invoice.pdf"),
            &[],
            &[home.clone()]
        ));
        assert!(!should_skip_located(
            Path::new("/home/x/.config/app/settings.json"),
            &[],
            &[PathBuf::from("/home/x/.config")]
        ));
    }
}
