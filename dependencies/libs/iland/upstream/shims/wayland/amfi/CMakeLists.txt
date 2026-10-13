add_executable(amfiexceptiond src/exception.c)

# exception.c uses Objective-C (Foundation, objc/runtime, @autoreleasepool).
# The .c extension makes CMake pick the C frontend by default, which rejects the
# ObjC syntax. Force the Objective-C compiler.
set_source_files_properties(src/exception.c PROPERTIES LANGUAGE OBJC)

target_compile_options(amfiexceptiond PRIVATE
  -Wall -Wextra
  -Wno-deprecated-declarations
)

target_link_libraries(amfiexceptiond PRIVATE
  -lobjc
  "-framework Foundation"
)

add_custom_command(TARGET amfiexceptiond POST_BUILD
  COMMAND codesign -s - $<TARGET_FILE:amfiexceptiond>
  COMMENT "Adhoc codesigning amfiexceptiond"
)
