# Consigliere

Consigliere is a North America-focused market intelligence prototype for iOS. It connects political events and public congressional disclosures with transparent, timestamped market context while avoiding personalized investment recommendations.

## Prototype capabilities

- U.S. and Canadian market pulse with European, Asia-Pacific, and global context
- Congressional disclosure and presidential social-post event feed
- Search across equities, indices, ETFs, futures, and physical crude assessments
- Event-window market analysis with provenance and freshness labels
- Watchlist and hypothetical portfolio exposure diagnostics
- Light/dark appearance and US English, Canadian English, Spanish, and French localization
- Accessibility support for Dynamic Type, VoiceOver, and color-independent status cues

The included provider is deterministic prototype data. Production deployment requires licensed market/social feeds, backend ingestion, legal review, and verification of redistribution rights.

See [the architecture note](docs/architecture.md) for the production ingestion boundary and compliance posture.

## Open the project

Open `Consigliere.xcodeproj` in Xcode 15 or newer and run the `Consigliere` scheme on iOS 17 or newer.

If Xcode has never been launched on the machine, accept Apple’s Xcode license before running command-line builds.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

## Disclaimer

Consigliere is an informational research tool. Nothing in the app constitutes investment advice, a recommendation, or an offer to buy or sell a security.
