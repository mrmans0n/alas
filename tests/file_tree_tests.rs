use alas::project::FileTreeService;
use pretty_assertions::assert_eq;
use tempfile::tempdir;

#[test]
fn file_tree_lists_directories_before_files_and_skips_git() {
    let temp = tempdir().unwrap();
    std::fs::create_dir(temp.path().join("src")).unwrap();
    std::fs::create_dir(temp.path().join(".git")).unwrap();
    std::fs::write(
        temp.path().join("Cargo.toml"),
        "[package]\nname = \"demo\"\n",
    )
    .unwrap();
    std::fs::write(temp.path().join("src").join("main.rs"), "fn main() {}\n").unwrap();

    let tree = FileTreeService::new().load(temp.path(), 2).unwrap();
    let child_names: Vec<_> = tree
        .children
        .iter()
        .map(|child| child.name.as_str())
        .collect();

    assert_eq!(child_names, vec!["src", "Cargo.toml"]);
}

#[test]
fn file_tree_depth_limits_children() {
    let temp = tempdir().unwrap();
    std::fs::create_dir_all(temp.path().join("a").join("b")).unwrap();
    std::fs::write(temp.path().join("a").join("b").join("file.txt"), "hello\n").unwrap();

    let tree = FileTreeService::new().load(temp.path(), 1).unwrap();
    let a = tree
        .children
        .iter()
        .find(|child| child.name == "a")
        .unwrap();

    assert!(a.children.is_empty());
}
