#!/usr/bin/env ruby
# frozen_string_literal: true

root = File.expand_path("../Sources/CoreDeviceShim", __dir__)

def replace_once(path, old, new)
  text = File.read(path)
  count = text.scan(old).length
  abort "expected one patch context in #{path}, found #{count}" unless count == 1
  File.write(path, text.sub(old, new))
end

assembly = File.join(root, "CoreDeviceTrampolines.S")
replace_once(
  assembly,
  ".long _SSCDMotionManager - _SSCDMotionManagerDescriptor\n",
  <<~ASM
    // The C pointer accessor fills the relative entry point at runtime. Mach-O's
    // x86_64 assembler cannot encode a subtraction relocation to a function in a
    // different object file.
    .long 0
  ASM
)
{
  "SSCDHingeReadback" => "SSCDHingeReadbackDescriptor",
  "SSCDDeviceStateReadback" => "SSCDDeviceStateReadbackDescriptor",
  "SSCDOrientationReadback" => "SSCDOrientationReadbackDescriptor"
}.each do |entry, descriptor|
  replace_once(assembly, ".long _#{entry} - _#{descriptor}\n", ".long 0\n")
end

motion = File.join(root, "CoreDeviceMotionShim.c")
replace_once(
  motion,
  "extern int32_t SSCDMotionManagerDescriptor[2];\n",
  <<~C
    extern int32_t SSCDMotionManagerDescriptor[2];
    void __attribute__((swiftasynccall)) SSCDMotionManager(void *, void *, void *, void *, void *,
                                                           void * __attribute__((swift_async_context)));
  C
)
replace_once(
  motion,
  "        if (!motionTarget || !descriptor || !supportsTarget || !metadataTarget || !errorTarget) return;\n",
  [
    "        if (!motionTarget || !descriptor || !supportsTarget || !metadataTarget || !errorTarget) return;",
    "        intptr_t entryOffset = (intptr_t)&SSCDMotionManager - (intptr_t)SSCDMotionManagerDescriptor;",
    "        if (entryOffset < INT32_MIN || entryOffset > INT32_MAX) return;",
    "        SSCDMotionManagerDescriptor[0] = (int32_t)entryOffset;"
  ].join("\n") + "\n"
)

hinge = File.join(root, "CoreDeviceHingeReadbackShim.c")
replace_once(
  hinge,
  "extern int32_t SSCDHingeReadbackDescriptor[2];\n",
  <<~C
    extern int32_t SSCDHingeReadbackDescriptor[2];
    void __attribute__((swiftasynccall)) SSCDHingeReadback(void *, void *, void *, void *,
                                                           void * __attribute__((swift_async_context)));
  C
)
replace_once(
  hinge,
  "        if (!monitorTarget || !descriptor || !snapshotMetadata || !configMetadata) return;\n",
  [
    "        if (!monitorTarget || !descriptor || !snapshotMetadata || !configMetadata) return;",
    "        intptr_t entryOffset = (intptr_t)&SSCDHingeReadback - (intptr_t)SSCDHingeReadbackDescriptor;",
    "        if (entryOffset < INT32_MIN || entryOffset > INT32_MAX) return;",
    "        SSCDHingeReadbackDescriptor[0] = (int32_t)entryOffset;"
  ].join("\n") + "\n"
)

state = File.join(root, "CoreDeviceStateReadbackShim.c")
replace_once(
  state,
  "extern int32_t SSCDDeviceStateReadbackDescriptor[2], SSCDOrientationReadbackDescriptor[2];\n",
  <<~C
    extern int32_t SSCDDeviceStateReadbackDescriptor[2], SSCDOrientationReadbackDescriptor[2];
    void __attribute__((swiftasynccall)) SSCDDeviceStateReadback(void *, void *, void *,
                                                                 void * __attribute__((swift_async_context)));
    void __attribute__((swiftasynccall)) SSCDOrientationReadback(void *, void *, void *, void *,
                                                                 void * __attribute__((swift_async_context)));
  C
)
replace_once(
  state,
  "        if (!stateTarget || !descriptor || !stateSupport || !stateMetadata) return;\n",
  [
    "        if (!stateTarget || !descriptor || !stateSupport || !stateMetadata) return;",
    "        intptr_t entryOffset = (intptr_t)&SSCDDeviceStateReadback - (intptr_t)SSCDDeviceStateReadbackDescriptor;",
    "        if (entryOffset < INT32_MIN || entryOffset > INT32_MAX) return;",
    "        SSCDDeviceStateReadbackDescriptor[0] = (int32_t)entryOffset;"
  ].join("\n") + "\n"
)
replace_once(
  state,
  "        if (!orientationTarget || !descriptor || !orientationMetadata) return;\n",
  [
    "        if (!orientationTarget || !descriptor || !orientationMetadata) return;",
    "        intptr_t entryOffset = (intptr_t)&SSCDOrientationReadback - (intptr_t)SSCDOrientationReadbackDescriptor;",
    "        if (entryOffset < INT32_MIN || entryOffset > INT32_MAX) return;",
    "        SSCDOrientationReadbackDescriptor[0] = (int32_t)entryOffset;"
  ].join("\n") + "\n"
)
