#pragma once
#include <Arduino.h>

struct InvisCommState {
    uint32_t H;
    uint32_t M1;
    uint32_t M2;
    uint32_t M3;
    uint32_t phase;
};

class InvisCommEngine {
public:
    InvisCommEngine(uint32_t sharedKey, const char* alphabet, uint8_t alphabetLen);
    bool encodeSymbol(char symbol, uint32_t position, uint16_t& coordinate);
    bool decodeCoordinate(uint16_t coordinate, uint32_t position, char& symbol);
    const InvisCommState& state() const { return state_; }

private:
    uint32_t sharedKey_;
    const char* alphabet_;
    uint8_t alphabetLen_;
    InvisCommState state_;

    int16_t alphabetIndex(char c) const;
    void deriveMap(uint32_t position, uint16_t& base, uint16_t& stride) const;
    void evolve(uint32_t position, uint16_t coordinate);
    static uint16_t inverseOdd1024(uint16_t x);
    static void put32(uint8_t* p, uint32_t v);
    static uint32_t get32(const uint8_t* p);
};
