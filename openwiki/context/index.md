# Files

- [Hierarchical Context Store](hierarchical-context-store.md) - How the AgentHarnessKitContext module stores a session's messages, folds finished ranges into summary blocks through the compress, decompress, search_context and context_status tools, decides which messages are protected, nudges the model when the window fills, and persists state through the GRDB-backed or in-memory persistence stores.
