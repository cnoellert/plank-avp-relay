/* Noise-C public test vector; see tests/NOISE-C-LICENSE. */
static const char init_prologue[] = "50726f6c6f677565313233";
static const char init_static[] = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1";
static const char init_ephemeral[] = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a";
static const char init_remote_static[] = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62";
static const char resp_static[] = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893";
static const char resp_ephemeral[] = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b";
static const char handshake_hash[] = "00e51d2aac81a9b8ebe441d6af3e1c8efc0f030cc608332edcb42588ff6a0ce26415ddc106e95277a5e6d54132f1e5245976b89caf96d262f1fe5a7f0c55c078";
static const char payload_0[] = "4c756477696720766f6e204d69736573";
static const char ciphertext_0[] = "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944ba83a447b38c83e327ad936929812f624884847b7831e95e197b2f797088efdd232fe541af156ec6d0657602902a8c3ee64e470f4b6fcd9298ce0b56fe20f86e60d9d933ec6e103ffb09e6001d6abb64";
static const char payload_1[] = "4d757272617920526f746862617264";
static const char ciphertext_1[] = "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088439f069b267a06b3de3ecb1043bcb09807c6cd101f3826192a65f11ef3fe4317";
static const char payload_2[] = "462e20412e20486179656b";
static const char ciphertext_2[] = "cd54383060e7a28434cca27fb1cc524cfbabeb18181589df219d07";
static const char payload_3[] = "4361726c204d656e676572";
static const char ciphertext_3[] = "a856d3bf0246bfc476c655009cd1ed677b8dcc5b349ae8ef2a05f2";
