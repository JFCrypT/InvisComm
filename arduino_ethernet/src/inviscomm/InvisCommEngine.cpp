#include "inviscomm/InvisCommEngine.h"
#include "inviscomm/Sha256Lite.h"

void InvisCommEngine::put32(uint8_t* p,uint32_t v){ p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
uint32_t InvisCommEngine::get32(const uint8_t* p){ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }

InvisCommEngine::InvisCommEngine(uint32_t sharedKey,const char* alphabet,uint8_t alphabetLen)
: sharedKey_(sharedKey), alphabet_(alphabet), alphabetLen_(alphabetLen) {
    uint8_t seed[12]={'I','n','v','i','s','C','o','m','m',0,0,0};
    seed[9]=(uint8_t)(sharedKey>>16); seed[10]=(uint8_t)(sharedKey>>8); seed[11]=(uint8_t)sharedKey;
    uint8_t d[32]; Sha256Lite::digest(seed,sizeof(seed),d);
    state_.H=get32(d); state_.M1=get32(d+4); state_.M2=get32(d+8); state_.M3=get32(d+12); state_.phase=0;
}

int16_t InvisCommEngine::alphabetIndex(char c) const{
    for(uint8_t i=0;i<alphabetLen_;i++) if(alphabet_[i]==c) return i;
    return -1;
}

void InvisCommEngine::deriveMap(uint32_t position,uint16_t& base,uint16_t& stride) const{
    uint8_t in[28];
    put32(in,sharedKey_); put32(in+4,state_.H); put32(in+8,state_.M1); put32(in+12,state_.M2);
    put32(in+16,state_.M3); put32(in+20,state_.phase); put32(in+24,position);
    uint8_t d[32]; Sha256Lite::digest(in,sizeof(in),d);
    base=(uint16_t)(((uint16_t)d[0]<<8)|d[1]) & 0x03FF;
    stride=(uint16_t)((((uint16_t)d[2]<<8)|d[3]) & 0x03FF) | 1U;
}

uint16_t InvisCommEngine::inverseOdd1024(uint16_t x){
    // Newton iteration modulo powers of two; x is odd.
    uint16_t y=x;
    y=(uint16_t)(y*(2U-x*y));
    y=(uint16_t)(y*(2U-x*y));
    y=(uint16_t)(y*(2U-x*y));
    y=(uint16_t)(y*(2U-x*y));
    return y & 0x03FF;
}

void InvisCommEngine::evolve(uint32_t position,uint16_t coordinate){
    uint8_t in[30];
    put32(in,sharedKey_); put32(in+4,state_.H); put32(in+8,state_.M1); put32(in+12,state_.M2);
    put32(in+16,state_.M3); put32(in+20,state_.phase); put32(in+24,position);
    in[28]=(uint8_t)(coordinate>>8); in[29]=(uint8_t)coordinate;
    uint8_t d[32]; Sha256Lite::digest(in,sizeof(in),d);
    const uint32_t oldM2=state_.M2;
    state_.M1=oldM2;
    state_.M2=state_.M3;
    state_.M3=get32(d+8);
    state_.H=get32(d) ^ get32(d+16);
    state_.phase++;
}

bool InvisCommEngine::encodeSymbol(char symbol,uint32_t position,uint16_t& coordinate){
    const int16_t idx=alphabetIndex(symbol); if(idx<0) return false;
    uint16_t base,stride; deriveMap(position,base,stride);
    coordinate=(uint16_t)((base + ((uint32_t)(uint16_t)idx * stride)) & 0x03FF);
    evolve(position,coordinate); return true;
}

bool InvisCommEngine::decodeCoordinate(uint16_t coordinate,uint32_t position,char& symbol){
    uint16_t base,stride; deriveMap(position,base,stride);
    const uint16_t inv=inverseOdd1024(stride);
    const uint16_t delta=(coordinate-base)&0x03FF;
    const uint16_t idx=(uint16_t)(((uint32_t)delta*inv)&0x03FF);
    if(idx>=alphabetLen_) return false;
    symbol=alphabet_[idx]; evolve(position,coordinate); return true;
}
