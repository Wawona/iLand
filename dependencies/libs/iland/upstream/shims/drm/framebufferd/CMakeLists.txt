add_executable(framebufferd src/main.c)

# main.c is Objective-C (Foundation/QuartzCore, objc_msgSend, @autoreleasepool).
# The .c extension makes CMake pick the C frontend by default, which rejects the
# ObjC syntax in the Foundation headers. Force the Objective-C compiler.
set_source_files_properties(src/main.c PROPERTIES LANGUAGE OBJC)

target_include_directories(framebufferd PRIVATE
  ${CMAKE_SOURCE_DIR}/shims/drm/drm/include
)

target_link_libraries(framebufferd PRIVATE
  displaysurface
  symrez
  -lobjc
  "-framework Foundation"
  "-framework QuartzCore"
  "-framework IOSurface"
  "-framework IOKit"
  "-framework CoreGraphics"
  "-framework CoreVideo"
)

# CoreBedtime ships entitlements.plist for framebufferd (iomfb windowserver
# profile, displayservice, …). Sign with it so DispDrvInit can own the panel.
add_custom_command(TARGET framebufferd POST_BUILD
  COMMAND codesign -s - --force --entitlements
          ${CMAKE_CURRENT_SOURCE_DIR}/entitlements.plist
          $<TARGET_FILE:framebufferd>
  COMMENT "Adhoc codesigning framebufferd with Mode B entitlements"
)

