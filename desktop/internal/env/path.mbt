// The path variable: its separator, and the two ways this app prepends a
// directory to it. Shared by the engine's child environments and the bundled
// MoonBit toolchain's, which spawn children the same way and must agree on
// the platform separator and on the Windows `Path`-vs-`PATH` rule.

///|
#cfg(platform="windows")
const PathSep : String = ";"

///|
#cfg(not(platform="windows"))
const PathSep : String = ":"

///|
/// The platform's path-variable separator: `;` on Windows, `:` elsewhere.
///
/// Deliberately a function, not a `pub const`. A public `#cfg` const bakes
/// whichever value survived into `pkg.generated.mbti`, so regenerating the
/// interface on Windows rewrites it and the committed one no longer matches
/// — every other `#cfg` const here (`ExecutableSuffix`) stays private for the
/// same reason.
pub fn path_sep() -> String {
  PathSep
}

///|
/// `bin_dir` prepended to `current_path`, or `bin_dir` alone when there is no
/// path to extend.
pub fn prepend_to_path_env(bin_dir : String, current_path : String?) -> String {
  if current_path is Some(path) && !path.is_empty() {
    "\{bin_dir}\{PathSep}\{path}"
  } else {
    bin_dir
  }
}

///|
/// Prepend `bin_dir` to the environment block's path variable, in place, and
/// return the updated value. Windows blocks commonly spell the key `Path`
/// (and `@sys.get_env_vars` preserves that spelling); a block passed to a
/// child with `inherit_env=false` that carried a separate uppercase `PATH`
/// beside it would leave two path variables and make which one the child
/// observes a runtime coin toss. Update the spelling that already exists and
/// drop any duplicates.
pub fn prepend_path_entry(
  env : Map[String, String],
  bin_dir : String,
) -> String {
  let mut key = "PATH"
  let mut current : String? = None
  let duplicates : Array[String] = []
  for name, value in env {
    if name.to_upper() == "PATH" {
      if current is None {
        key = name
        current = Some(value)
      } else {
        duplicates.push(name)
      }
    }
  }
  for name in duplicates {
    env.remove(name)
  }
  let joined = prepend_to_path_env(bin_dir, current)
  env[key] = joined
  joined
}
