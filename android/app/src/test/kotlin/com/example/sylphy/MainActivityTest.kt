package com.example.sylphy

import org.junit.Assert.assertEquals
import org.junit.Test

class MainActivityTest {
    @Test
    fun normalizesJniInternalNamesForAndroidClassLoader() {
        assertEquals(
            "androidx.security.crypto.MasterKey\$Builder",
            veilidBinaryClassName("androidx/security/crypto/MasterKey\$Builder"),
        )
    }

    @Test
    fun preservesBinaryClassNames() {
        assertEquals(
            "androidx.security.crypto.MasterKey",
            veilidBinaryClassName("androidx.security.crypto.MasterKey"),
        )
    }
}
