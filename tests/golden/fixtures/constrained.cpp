// constrained template params
template <std::convertible_to<bool> A, std::same_as<int> B>
void f();

template <std::convertible_to<bool> A>
concept Boolish = A;
