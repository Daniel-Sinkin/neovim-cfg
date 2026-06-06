namespace lldb { struct SBEvent {}; }
class Foo
{
    static bool EventIsTargetEvent(const lldb::SBEvent &event);
    SBValue *GetValue(int idx) const;
    void run() noexcept;
    auto trailing() const -> int;
};
bool freeFunc(int x);

class Bar
{
    [[nodiscard]] auto x() const noexcept -> int;
    [[nodiscard]] auto name() const noexcept -> const char*;
    auto reset(int n) noexcept -> Bar&;
};

// clang-format off
auto kept_raw(int a,    int b) -> int;
auto and_this  (float x)       -> float;
// clang-format on
