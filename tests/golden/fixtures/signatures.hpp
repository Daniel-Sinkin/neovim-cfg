namespace lldb { struct SBEvent {}; }
class Foo
{
    static bool EventIsTargetEvent(const lldb::SBEvent &event);
    SBValue *GetValue(int idx) const;
    void run() noexcept;
    auto trailing() const -> int;
};
bool freeFunc(int x);
