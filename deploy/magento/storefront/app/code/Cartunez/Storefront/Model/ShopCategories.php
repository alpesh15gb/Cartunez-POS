<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Model;

use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\ResourceModel\Category\CollectionFactory;
use Magento\Framework\App\ResourceConnection;
use Magento\Store\Model\StoreManagerInterface;

/**
 * The shop's main departments (Audio, Interior, Lighting, Dashcams & safety,
 * Styling, Performance & care, Installation), found among the POS categories by
 * name, case-insensitive. Each department accepts a short name ("Audio") and
 * the longer ones ("Audio & Speakers", "Audio & Infotainment"...); the first
 * name in the list that exists is the department's page and item count. Used by
 * the home category tiles, the "Featured" filter chips and the cyan
 * "Studio fitting" tag on cards (Audio, Interior, Lighting and Installation:
 * the studio fits those parts). Results are kept for the request.
 */
class ShopCategories
{
    /** department => category names, preferred first */
    public const GROUPS = [
        'audio' => ['Audio', 'Audio & Speakers', 'Audio & Infotainment', 'Audio and Speakers', 'Car Audio', 'Speakers', 'Infotainment'],
        'interior' => ['Interior', 'Interior Makeovers', 'Interior Accessories', 'Interiors'],
        'lighting' => ['Lighting', 'Lighting & Headlamps', 'Exterior & Lighting', 'Lights', 'Headlamps', 'Exterior'],
        'safety' => ['Dashcams', 'Dashcam', 'Dashcams & Safety', 'Dash Cameras', 'Safety', 'Security'],
        'styling' => ['Styling', 'Styling & Detailing', 'Styling & Sun Control', 'Sun Control', 'Window Film'],
        'performance' => ['Performance', 'Performance & Filters', 'Performance & Detailing', 'Filters', 'Detailing', 'Car Care'],
        'installation' => ['Installation', 'Installations', 'Studio Installation', 'Installation Services', 'Fitting'],
    ];

    /** Departments whose parts the studio fits ("Studio fitting" tag). */
    public const STUDIO = ['audio', 'interior', 'lighting', 'installation'];

    /** @var array<string, array{id: int, name: string, url: string, count: int}>|null */
    private ?array $resolved = null;
    /** @var array<int, string[]> category id => departments */
    private array $groupsOfCategory = [];
    /** @var array<int, string[]> product id => departments */
    private array $productGroups = [];

    public function __construct(
        private readonly CollectionFactory $categories,
        private readonly ResourceConnection $resource,
        private readonly StoreManagerInterface $storeManager
    ) {
    }

    /**
     * The department categories that exist in this store.
     *
     * @return array<string, array{id: int, name: string, url: string, count: int}>
     */
    public function resolve(): array
    {
        if ($this->resolved !== null) {
            return $this->resolved;
        }
        $this->resolved = [];
        $names = [];
        foreach (self::GROUPS as $list) {
            foreach ($list as $name) {
                $names[] = $name;
            }
        }
        $store = $this->storeManager->getStore();
        $collection = $this->categories->create()
            ->setStoreId((int)$store->getId())
            ->addAttributeToSelect(['name', 'url_key', 'url_path'])
            ->addAttributeToFilter('name', ['in' => array_values(array_unique($names))])
            ->addIsActiveFilter()
            ->addPathFilter('^1/' . (int)$store->getRootCategoryId() . '/')
            ->setOrder('level', 'ASC')
            ->setOrder('position', 'ASC');
        /** @var array<string, Category> $byName lowercase name => shallowest category */
        $byName = [];
        /** @var Category $category */
        foreach ($collection as $category) {
            $key = mb_strtolower(trim((string)$category->getName()));
            $byName[$key] ??= $category;
        }
        foreach (self::GROUPS as $group => $list) {
            foreach ($list as $name) {
                $category = $byName[mb_strtolower($name)] ?? null;
                if ($category === null) {
                    continue;
                }
                $id = (int)$category->getId();
                $this->groupsOfCategory[$id][] = $group;
                if (!isset($this->resolved[$group])) {
                    $this->resolved[$group] = [
                        'id' => $id,
                        'name' => (string)$category->getName(),
                        'url' => (string)$category->getUrl(),
                        'count' => 0,
                    ];
                }
            }
        }
        if ($this->resolved) {
            $counts = $this->counts((int)$store->getId(), array_column($this->resolved, 'id'));
            foreach ($this->resolved as $group => $info) {
                $this->resolved[$group]['count'] = $counts[$info['id']] ?? 0;
            }
        }
        return $this->resolved;
    }

    /**
     * Loads the departments of these products in one query.
     *
     * @param int[] $productIds
     */
    public function preloadProducts(array $productIds): void
    {
        $ids = array_values(array_diff(array_unique(array_map('intval', $productIds)), array_keys($this->productGroups)));
        if (!$ids) {
            return;
        }
        foreach ($ids as $id) {
            $this->productGroups[$id] = [];
        }
        $this->resolve();
        $categoryIds = array_keys($this->groupsOfCategory);
        if (!$categoryIds) {
            return;
        }
        $db = $this->resource->getConnection();
        $storeId = (int)$this->storeManager->getStore()->getId();
        // The category index also lists parts of sub-categories under an anchor category.
        $table = $this->resource->getTableName('catalog_category_product_index_store' . $storeId);
        if (!$db->isTableExists($table)) {
            $table = $this->resource->getTableName('catalog_category_product');
        }
        $rows = $db->fetchAll(
            $db->select()
                ->distinct()
                ->from($table, ['product_id', 'category_id'])
                ->where('product_id IN (?)', $ids)
                ->where('category_id IN (?)', $categoryIds)
        );
        foreach ($rows as $row) {
            $productId = (int)$row['product_id'];
            foreach ($this->groupsOfCategory[(int)$row['category_id']] ?? [] as $group) {
                $this->productGroups[$productId][$group] = $group;
            }
        }
        foreach ($ids as $id) {
            $this->productGroups[$id] = array_values($this->productGroups[$id]);
        }
    }

    /** @return string[] departments of this product */
    public function groupsOf(int $productId): array
    {
        $this->preloadProducts([$productId]);
        return $this->productGroups[$productId] ?? [];
    }

    /** True for parts the studio fits (Audio, Interior, Lighting, Installation). */
    public function isStudioFit(int $productId): bool
    {
        return (bool)array_intersect($this->groupsOf($productId), self::STUDIO);
    }

    /**
     * @param int[] $categoryIds
     * @return array<int, int>
     */
    private function counts(int $storeId, array $categoryIds): array
    {
        $db = $this->resource->getConnection();
        $table = $this->resource->getTableName('catalog_category_product_index_store' . $storeId);
        if (!$categoryIds || !$db->isTableExists($table)) {
            return [];
        }
        $rows = $db->fetchPairs(
            $db->select()
                ->from($table, ['category_id', 'n' => new \Zend_Db_Expr('COUNT(DISTINCT product_id)')])
                ->where('category_id IN (?)', $categoryIds)
                ->where('visibility IN (?)', [2, 4])
                ->group('category_id')
        );
        return array_map('intval', $rows);
    }

    /** @return string[] cache tags: any category change, and parts added to or removed from these categories */
    public function getIdentities(): array
    {
        $this->resolve();
        $tags = [Category::CACHE_TAG];
        foreach (array_keys($this->groupsOfCategory) as $id) {
            $tags[] = Category::CACHE_TAG . '_' . $id;
            $tags[] = Product::CACHE_PRODUCT_CATEGORY_TAG . '_' . $id;
        }
        return $tags;
    }
}
