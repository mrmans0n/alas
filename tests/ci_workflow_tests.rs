#[test]
fn ubuntu_build_jobs_install_native_link_libraries() {
    let workflow = std::fs::read_to_string(".github/workflows/build.yml")
        .expect("build workflow should be readable");

    for package in ["libxcb1-dev", "libxkbcommon-x11-dev"] {
        assert!(
            workflow.contains(package),
            "build workflow must install {package} so Linux CI can link GPUI/X11 dependencies"
        );
    }
}
