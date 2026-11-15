// Linux keeps URLSession and friends in FoundationNetworking; re-exporting it
// here lets every file in this module use them with a plain `import Foundation`.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

// `os` on Apple platforms, the stand-ins in LinuxLogger.swift elsewhere: the
// modules above import neither and get whichever this platform has.
#if canImport(os)
@_exported import os
#endif

// Apple's Foundation brings Observation along; Linux's doesn't.
@_exported import Observation
