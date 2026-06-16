# Paginated Data Fetching + List UI

Frontend convention for Expo apps using TanStack Query and React Native lists. Keep pagination state out of screens: the API function knows request params, the hook owns `useInfiniteQuery`, and the UI only renders a flat list.

## File split

```text
src/
├── api/
│   ├── things.ts              # request function + PAGE_SIZE
│   └── hooks/
│       └── things.ts          # useInfiniteQuery + mutations
├── lib/
│   └── query-client.ts        # query keys + QueryClient defaults
└── app/
    └── (tabs)/things/index.tsx # search, flatten pages, FlashList UI
```

Use one page shape everywhere:

```ts
export interface ThingPage {
  data: Thing[];
  total: number;
  offset: number;
  limit: number;
  nextOffset: number | null;
}
```

## Query keys

Use a base key for broad invalidation and a filtered list key for the infinite query.

```ts
export const queryKeys = {
  things: ["things"] as const,
  thingsList: (search: string) => ["things", { search }] as const,
};
```

After create/update/delete mutations, invalidate the base key so every filtered list refreshes:

```ts
qc.invalidateQueries({ queryKey: queryKeys.things });
```

## API function

```ts
export const THING_PAGE_SIZE = 30;

interface FetchThingsParams {
  offset?: number;
  limit?: number;
  search?: string;
}

export async function fetchThings({
  offset = 0,
  limit = THING_PAGE_SIZE,
  search = "",
}: FetchThingsParams = {}): Promise<ThingPage> {
  const params = new URLSearchParams({
    offset: String(offset),
    limit: String(limit),
  });

  const q = search.trim();
  if (q) params.set("q", q);

  return apiFetch<ThingPage>(`/things?${params.toString()}`);
}
```

## Infinite query hook

Normalize filters before they enter the query key. The screen passes user intent; the hook translates it into pagination mechanics.

```ts
export function useThingsQuery(search = "") {
  const normalizedSearch = search.trim();

  return useInfiniteQuery({
    queryKey: queryKeys.thingsList(normalizedSearch),
    queryFn: ({ pageParam }) =>
      fetchThings({
        offset: pageParam,
        limit: THING_PAGE_SIZE,
        search: normalizedSearch,
      }),
    initialPageParam: 0,
    getNextPageParam: (lastPage) => lastPage.nextOffset,
  });
}
```

Do not store `offset`, `page`, or `nextOffset` in component state. TanStack Query already stores it in the infinite-query cache.

## Flatten pages

Flatten pages once and derive the total from the first page.

```tsx
const {
  data,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
  isPending,
  isRefetching,
  refetch,
} = useThingsQuery(debouncedSearch);

const items = useMemo(() => data?.pages.flatMap((page) => page.data) ?? [], [data]);
const total = data?.pages[0]?.total ?? 0;
```

## Load-more guard

Always guard `onEndReached`. React Native list end events can fire more than once during momentum, layout changes, or a refresh.

```tsx
const handleEndReached = useCallback(() => {
  if (!hasNextPage || isFetchingNextPage) return;
  void fetchNextPage();
}, [fetchNextPage, hasNextPage, isFetchingNextPage]);
```

## List UI

The UI has four distinct states:

- Initial load: full-screen spinner from `isPending`
- Loaded data: flattened `items`
- Pull-to-refresh: `refreshing={isRefetching && !isFetchingNextPage}`
- Loading next page: footer spinner from `isFetchingNextPage`

```tsx
{isPending ? (
  <View className="flex-1 items-center justify-center">
    <ActivityIndicator color={colors.primary} />
  </View>
) : (
  <FlashList
    alwaysBounceVertical
    className="flex-1"
    data={items}
    keyExtractor={(item) => item.id}
    renderItem={renderThingItem}
    contentContainerStyle={styles.listContent}
    ListEmptyComponentStyle={styles.emptyState}
    refreshing={isRefetching && !isFetchingNextPage}
    onRefresh={() => void refetch()}
    onEndReached={handleEndReached}
    onEndReachedThreshold={0.5}
    ListEmptyComponent={emptyThings}
    ListFooterComponent={
      isFetchingNextPage ? (
        <View className="py-4">
          <ActivityIndicator color={colors.primary} />
        </View>
      ) : null
    }
  />
)}
```

```tsx
const styles = StyleSheet.create({
  emptyState: {
    flexGrow: 1,
  },
  listContent: {
    flexGrow: 1,
    paddingBottom: 120,
    paddingHorizontal: 16,
  },
});
```

`flexGrow: 1` on both the list content and empty component keeps the empty state vertically centered while preserving normal scrolling once data exists.

## Mutations on infinite data

For optimistic deletion, update every cached filtered list under the base key. Snapshot first, then restore on error.

```ts
type ThingSnapshot = Array<[QueryKey, InfiniteData<ThingPage> | undefined]>;

export function useDeleteThingMutation() {
  const qc = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => deleteThing(id),
    onMutate: async (id) => {
      await qc.cancelQueries({ queryKey: queryKeys.things });

      const prev = qc.getQueriesData<InfiniteData<ThingPage>>({
        queryKey: queryKeys.things,
      }) as ThingSnapshot;

      qc.setQueriesData<InfiniteData<ThingPage>>(
        { queryKey: queryKeys.things },
        (current) => {
          if (!current) return current;

          const removed = current.pages.some((page) =>
            page.data.some((item) => item.id === id),
          );
          if (!removed) return current;

          return {
            ...current,
            pages: current.pages.map((page) => ({
              ...page,
              data: page.data.filter((item) => item.id !== id),
              total: Math.max(0, page.total - 1),
            })),
          };
        },
      );

      return { prev };
    },
    onError: (_error, _id, ctx) => {
      for (const [queryKey, data] of ctx?.prev ?? []) {
        qc.setQueryData(queryKey, data);
      }
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: queryKeys.things });
    },
  });
}
```

## Admin-only "load all" variant

For small admin screens where infinite scroll is not desired, a normal `useQuery` may loop through pages and return one array. Keep the same `nextOffset` contract.

```ts
const things = useQuery({
  queryKey: adminQueryKeys.things,
  queryFn: async () => {
    const rows: Thing[] = [];
    let offset: number | null = 0;

    while (offset !== null) {
      const page = await fetchThings({ offset, limit: 100 });
      rows.push(...page.data);
      offset = page.nextOffset;
    }

    return rows;
  },
});
```

Use this only for admin tables or bounded datasets. User-facing mobile feeds should use the infinite-list pattern above.
