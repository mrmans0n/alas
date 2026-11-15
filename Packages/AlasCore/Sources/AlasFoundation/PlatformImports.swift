// Linux keeps URLSession and friends in FoundationNetworking; re-exporting it
// here lets every file in this module use them with a plain `import Foundation`.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
