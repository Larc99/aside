**What this changes**

**How you verified it**
`swift test` is necessary but not sufficient: the suite is pure logic, so it
says nothing about whether a click lands, a window takes focus, or how anything
looks. If this touches event delivery, layering, focus or geometry, please say
what you exercised in the assembled `build/Aside.app`.

- [ ] `swift test` passes
- [ ] `scripts/make_app.sh` still assembles, if the build or bundle changed
- [ ] `docs/SPEC.md` updated, if behaviour it describes changed
- [ ] Fixed geometry in `docs/MACOS_NATIVE_UX.md` unchanged, or the reason recorded
