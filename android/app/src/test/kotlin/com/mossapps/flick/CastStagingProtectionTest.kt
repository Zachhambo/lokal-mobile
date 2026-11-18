package com.mossapps.flick

import java.nio.file.Files
import java.io.File
import org.junit.Test
import org.junit.Assert.*

class CastStagingProtectionTest {
    @Test fun onlyActiveFilesInsideStagingSurviveEviction() {
        val directory = Files.createTempDirectory("cast-staging").toFile()
        try {
            val playing = File(directory, "playing.flac")
            val next = File(directory, "next.flac")
            val old = File(directory, "old.flac")
            val outside = File(directory.parentFile, "outside.flac")
            CastStagingProtection.update(listOf(playing.path, next.path, outside.path), directory)
            assertTrue(CastStagingProtection.contains(playing))
            assertTrue(CastStagingProtection.contains(next))
            assertFalse(CastStagingProtection.contains(old))
            assertFalse(CastStagingProtection.contains(outside))
            CastStagingProtection.update(listOf(next.path), directory)
            assertFalse(CastStagingProtection.contains(playing))
            CastStagingProtection.update(emptyList(), directory)
            assertFalse(CastStagingProtection.contains(next))
        } finally { directory.delete() }
    }
}
