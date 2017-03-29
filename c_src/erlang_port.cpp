#include "erlang_port.h"

using __gnu_cxx::stdio_filebuf;

// Swaps big-endian to little-endian or opposite
template <class T> void EndianSwap(T *buffer) {
  unsigned char *mem = reinterpret_cast<unsigned char *>(buffer);
  std::reverse(mem, mem + sizeof(T));
}

ErlangPort::ErlangPort() :
    input(new stdio_filebuf<char>(PORTIN_FILENO, std::ios::in)),
    output(new stdio_filebuf<char>(PORTOUT_FILENO, std::ios::out)) {
  erl_init(NULL, 0);
  // auto result = cuInit(0);
  // if (result != CUDA_SUCCESS) throw new Error(CudaDriverError(result));
}

ErlangPort::~ErlangPort() {
  if (tuple) erl_free_compound(tuple);
  if (func) erl_free_term(func);
  if (arg) erl_free_term(arg);
  if (result) erl_free_term(result);
  if (driver) delete driver;
}

uint32_t ErlangPort::ReadPacketLength() {
  uint32_t len;
  input.read(reinterpret_cast<char*>(&len), sizeof(len));
  EndianSwap(&len);
  return len;
}

void ErlangPort::WritePacketLength(uint32_t len) {
  EndianSwap(&len);
  output.write(reinterpret_cast<char*>(&len), sizeof(len));
}

void ErlangPort::Loop() {
  while(true) {
    // Read packet length, 4 bytes
    uint32_t len = ReadPacketLength();
    // Read packet data, len bytes
    char* buf = new char[len];
    input.read(buf, len);
    // Decode packet
    tuple = erl_decode(reinterpret_cast<unsigned char *>(buf));
    if (!ERL_IS_TUPLE(tuple) || ERL_TUPLE_SIZE(tuple) != 2) continue;
    // Retrieve function name and argument
    func  = erl_element(1, tuple);
    arg   = erl_element(2, tuple);
    delete[] buf;

    // If first element of tuple is not an atom - skip it
    if (!ERL_IS_ATOM(func)) continue;

    // First tuple element is atom
    std::string atomFunc(ERL_ATOM_PTR(func));
    // Search for registered functions
    auto handler = handlers.find(atomFunc);
    // If there are no function to handle - skip packet
    if (handler == handlers.end()) continue;
    result = NULL;
    // Handler founded - call it
    try {
      result = handler->second(this, arg);
    } catch (Error &e) {
      result = e.AsTerm();
    }

    if (result) {
      // if we have result - return it to erlang
      len = erl_term_len(result);
      buf = new char[len];
      erl_encode(result, reinterpret_cast<unsigned char *>(buf));
      WritePacketLength(len);
      output.write(buf, len);
      output.flush();
    }
  };
}

void ErlangPort::AddHandler(std::string name, ErlangHandler handler) {
  handlers.insert(std::pair<std::string, ErlangHandler>(name, handler));
}

void ErlangPort::RemoveHandler(std::string name) {
  handlers.erase(name);
}
