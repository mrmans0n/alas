//! Throwaway test for the PR shepherd smoke run. Fails on purpose so CI
//! reports a failing check that the shepherd sends back to the agent.

#[test]
fn shepherd_smoke_ci_failure() {
    let expected_protocol_lines = 2;
    assert_eq!(expected_protocol_lines, 3, "shepherd smoke: expected 3 protocol lines");
}
