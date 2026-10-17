# Native copy comparison previews

`script/build_copy_preview.py` builds the actual SwiftUI views from a fixed Git revision with an isolated application identity. It requires Xcode, XcodeGen, Python and PyYAML. The script creates a source stage and dedicated DerivedData directory, signs the preview locally, verifies its identity, and writes a build receipt. It does not install or launch the application.

```sh
python3 script/build_copy_preview.py --variant After --ref HEAD --destination .build/copy-preview/after
```

Use `Before` for the baseline revision. Both variants use the same screenshot harness. Baseline product views stay unchanged; only the isolated launch guard, recorder hook and packaging settings are added to the source stage. The exact preview IDs always select offline fixture mode, including reopening without environment variables. No helper or LaunchAgent is embedded. Production providers, collectors and SM registration remain disconnected.

For a copy comparison, place previously queried, frozen `HistoryQueryResult` JSON files named `summary.json` and `detail.json` in a private input directory. The recorder checks the query scope against the requested range before displaying either result. Open the exact bundle path returned by the build receipt with `--copy-input=<directory>` and `--copy-output=<new-directory>`. Keep runtime input and output in a task-owned private temporary directory to avoid macOS Documents permission prompts. The output directory must already exist and be empty. Both sides receive the same frozen results and sample data. A local controller can collect the PNGs and receipts afterward.

The harness only reads the application-note preference; it uses an in-memory note store and never writes production preferences or history. Other pages use clearly identified sample data. These screenshots demonstrate copy and layout at fixed sizes; they do not establish live collection, notifications, keyboard interaction or full native acceptance. The harness is excluded from Release builds.
