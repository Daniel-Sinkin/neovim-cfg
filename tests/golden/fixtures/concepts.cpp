namespace dans::test
{
template <typename V>
concept StringLike = std::convertible_to<V, std::string_view>;
template <typename R>
concept StringRange = input_range<R> and StringLike<ValueOf<R>>;
template <typename T>
concept IsInt = std::same_as<T, int>;
template <typename F>
concept Callback = invocable<F, int>;
template <typename T>
concept CharCol = CharLike<RefOf<T>>;
template <typename T>
concept BoolCol = BoolLike<T> and IntLike<T>;

static_assert(std::same_as<ValueOf<R>, char>);
static_assert(std::same_as<std::underlying_type_t<VkResult>, int>);
}  // namespace dans::test
