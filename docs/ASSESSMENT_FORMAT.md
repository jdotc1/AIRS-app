# Scoped assessments — schema 1

B3 adds `airs.assessments` as a supported JSON attachment inside the existing
`.airsreview` envelope. Legacy audit, inspection and entitlement report fields
are unchanged. An assessment document retains original subject-document bytes
(the native flow uses a component inventory) and up to 64 separate results.
Subject bytes are limited to 512 KiB, the assessment JSON to 4 MiB, and all B0
outer-envelope budgets and duplicate-key checks still apply. Unknown schema
versions remain uninterpreted. Unknown outcomes and mismatched document digests
reject rather than infer success.

Each result records kind, subject-document SHA256, optional scoped-content SHA256,
component path, optional architecture, scope, start/completion time, host OS,
API/tool, flags, outcome and raw diagnostic. `@app-root` denotes the explicitly
selected app root. The content hash is a physical-tree-v1 digest, not the hash of
an executable alone. Its algorithm/scope is recorded in scopeDescription. A
metadata-document digest never substitutes for a content identity.

Operations are distinct:

- `signingInformation`: SecCodeCopySigningInformation with
  kSecCSSigningInformation, Security's default architecture selection. Extracted
  labels/flags are metadata only. Missing team or flags remain unavailable
  metadata, not an inconsistency. No static or distribution check is inferred.
- `signatureValidity`: SecStaticCodeCheckValidityWithErrors with explicit
  kSecCSStrictValidate, kSecCSCheckAllArchitectures and kSecCSCheckNestedCode;
  requirement=nil, network-access flag not requested. Validity applies to the
  selected app's sealed resources and nested code under those flags. Known
  signature/resource failures yield failed; unclassified system statuses remain
  unavailable with their raw OSStatus. This is not a distribution verdict.
- `localDistribution`: `/usr/sbin/spctl --assess --type execute --verbose=4`
  with the selected root as a separate argument. It may contact system services
  or network. Documented exit 0 is a scoped local-policy pass, 3 a denial; other
  statuses, signals, launch errors, time/output/drain interruptions are unavailable.
  Raw status/output remain diagnostic evidence. No localized-output parser,
  settings change, target launch, signing or notarization is performed.

Absent results display `notPerformed`. Cancellation produces `cancelled` after
owned operations settle. Synchronous Security calls cannot be interrupted; the
job remains owned until they return. The fixed helper has a 30-second deadline,
SIGTERM followed by owned-PID SIGKILL escalation after two seconds, 32 KiB retained
per output stream and a one-second post-exit drain deadline. Output continues to
be drained with nonblocking reads; inherited writers cannot stall completion.

## Content identity and reuse

The supported first scope is a local physical regular-file/directory tree with
at most 256 MiB total charged bytes, 4,096 entries, depth 32, 4,096-byte paths and
30 seconds per traversal. Per-node xattr names are limited to 64 KiB and each
attribute to 1 MiB. Links, non-UTF8 names, special/unreadable entries and exceeded
limits are explicitly unavailable. Framework/app trees with symlinks are therefore
outside this initial fresh-assessment subset.

The stream includes exact relative UTF-8 paths, mode/owner/group/flags, sorted
extended attributes (including a resource fork when within budget) and incremental
file-content SHA256. Descriptor-relative no-follow traversal observes inode,
device, size, timestamps and metadata before/after reads. The initial digest is
computed once, then reused with metadata/entry-identity admission checks before
and after each requested operation. Observable change overrides a raw pass,
retains its diagnostic and removes the usable scoped-content binding. This is
not an atomic bundle snapshot or protection against an adversarial filesystem
hiding changes between observations.

The inventory is captured inside that identity interval. Native UI does not repeat
a completed operation in the same review. Imported documents always have session
origin importedHistory, never a live identity or evaluation ID. Imported passed
records retain their historical result and timestamps; they cannot become fresh
validation by decoding or by matching a path/document digest. Re-export retains
the whole original archive, including opaque attachments.

## Apple API/tool references

Verified during implementation using apple-docs plus the selected Xcode beta
macOS 27.2 SDK declarations in Security/SecStaticCode.h, CSCommon.h and SecCode.h,
and the installed spctl(8) manual (including exit statuses).

- [Static validation API](https://developer.apple.com/documentation/security/secstaticcodecheckvaliditywitherrors(_:_:_:_:))
- [Apple code signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/)

Target remains macOS 14+. These references establish API semantics; actual host
qualification and unverified OS/distribution limits are in ASSESSMENT_RESULTS.md.
