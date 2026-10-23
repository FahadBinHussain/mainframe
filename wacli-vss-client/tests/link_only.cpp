#include "vss_client.h"
#ifdef _WIN32
int main() {
    // Instantiate factories to force linkage of the actual adapter. Deliberately
    // never resolve a root, initialize COM or request any snapshot.
    auto resolver = wacli::vss::make_native_resolver();
    auto backend = wacli::vss::make_native_backend();
    return resolver && backend ? 0 : 1;
}
#endif
