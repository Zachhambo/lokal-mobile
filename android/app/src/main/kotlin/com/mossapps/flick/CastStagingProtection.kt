package com.mossapps.flick

import java.io.File

/** Files currently exposed to a receiver, independent of the Activity lifetime.
 * This only affects eviction; it does not grant read access to arbitrary files.
 */
internal object CastStagingProtection {
    @Volatile private var protectedPaths: Set<String> = emptySet()

    fun update(paths: List<String>, stagingDirectory: File) {
        val root = stagingDirectory.canonicalFile
        protectedPaths = paths.mapNotNull { path ->
            try {
                val file = File(path).canonicalFile
                if (file.parentFile == root) file.path else null
            } catch (_: Exception) { null }
        }.toSet()
    }

    fun contains(file: File): Boolean = try {
        protectedPaths.contains(file.canonicalPath)
    } catch (_: Exception) { false }
}
