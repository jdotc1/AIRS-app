# AIRS 0.3.3 Preview — build 9

Build 9 fixes the comparison-sheet AttributeGraph sizing cycle and gives Settings
an appropriate minimum/default height. Comparison summaries are measured eagerly;
findings are presented in bounded pages of 50, with every finding and the complete
JSON/export retained. The v41 engine and report formats are unchanged.

The Apple silicon app is Developer ID signed, notarized and stapled. The accepted
build 9 binary, focused native tests and zero-cycle app-scene check are reused.
No repeated engine, corpus, vendor or signing qualification was performed.

See [release evidence and limits](docs/RELEASE_0_3_3_BUILD9.md). This remains a
preview: clean-machine, minimum-macOS, Intel-app and offline qualification are
incomplete. The prior build 7 release and assets remain available.
