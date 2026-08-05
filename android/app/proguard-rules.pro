# Veilid's keyring-manager loads AndroidX Security classes and their members
# through JNI. Keep the complete package so release shrinking does not remove
# constructors, nested enums, or methods that have no Java/Kotlin call sites.
-keep class androidx.security.crypto.** { *; }
