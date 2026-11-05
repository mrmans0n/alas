// Forward the Swift ABI unchanged, including swiftself and indirect results.
// All targets are checked by SSCoreDeviceInitialize before these are called.
#if defined(__aarch64__)
.macro FORWARD name, target
.text
.p2align 2
.globl _\name
_\name:
    adrp x16, _\target@PAGE
    ldr x16, [x16, _\target@PAGEOFF]
    br x16
.endmacro
#elif defined(__x86_64__)
.macro FORWARD name, target
.text
.globl _\name
_\name:
    jmp *_\target(%rip)
.endmacro
#endif

FORWARD SSCDShared, SSCDSharedTarget
FORWARD SSCDConnection, SSCDConnectionTarget
FORWARD SSCDCreateManager, SSCDCreateManagerTarget
FORWARD SSCDAllDevices, SSCDAllDevicesTarget
FORWARD SSCDInitialized, SSCDInitializedTarget
FORWARD SSCDIdentifier, SSCDIdentifierTarget
FORWARD SSCDVisibilityAllCases, SSCDVisibilityAllCasesTarget
FORWARD SSCDImplementation, SSCDImplementationTarget
FORWARD SSCDDisplayInfo, SSCDDisplayInfoTarget

.data
.p2align 2
.globl _SSCDImplementationTu
_SSCDImplementationTu:
.long _SSCDImplementation - _SSCDImplementationTu
.long 0
.globl _SSCDDisplayInfoTu
_SSCDDisplayInfoTu:
.long _SSCDDisplayInfo - _SSCDDisplayInfoTu
.long 0
.globl _SSCDMotionManagerDescriptor
_SSCDMotionManagerDescriptor:
// The C pointer accessor fills the relative entry point at runtime. Mach-O's
// x86_64 assembler cannot encode a subtraction relocation to a function in a
// different object file.
.long 0
.long 0
.globl _SSCDHingeReadbackDescriptor
_SSCDHingeReadbackDescriptor:
.long 0
.long 0
.globl _SSCDDeviceStateReadbackDescriptor
_SSCDDeviceStateReadbackDescriptor:
.long 0
.long 0
.globl _SSCDOrientationReadbackDescriptor
_SSCDOrientationReadbackDescriptor:
.long 0
.long 0
