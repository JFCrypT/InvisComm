#pragma once
#include <Arduino.h>

class Sha256Lite {
public:
    Sha256Lite();
    void reset();
    void update(const uint8_t* data, size_t len);
    void final(uint8_t out[32]);
    static void digest(const uint8_t* data, size_t len, uint8_t out[32]);

private:
    uint32_t state_[8];
    uint64_t bitLen_;
    uint8_t buffer_[64];
    uint8_t bufferLen_;
    void transform(const uint8_t block[64]);
};
