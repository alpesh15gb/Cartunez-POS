<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Model;

use Magento\Framework\App\ResourceConnection;
use Magento\Store\Model\StoreManagerInterface;

/**
 * Small, fast lookups shared by the storefront blocks: the brand of each part
 * (its category under "Brands"), its vehicle fitment (cz_fitment from the POS),
 * the label shown above the name on product cards, and the parts that fit every
 * vehicle. Plain SQL on Magento's own tables, results kept for the request.
 */
class Catalog
{
    /** @var array<string, int> attribute code@entity => id */
    private array $attributes = [];
    /** @var array<int, string>|null brand category id => name */
    private ?array $brands = null;
    /** @var array<int, string> product id => card label */
    private array $labels = [];

    public function __construct(
        private readonly ResourceConnection $resource,
        private readonly StoreManagerInterface $storeManager
    ) {
    }

    public function attributeId(string $code, string $entity = 'catalog_product'): int
    {
        $key = $code . '@' . $entity;
        if (!isset($this->attributes[$key])) {
            $db = $this->resource->getConnection();
            $this->attributes[$key] = (int)$db->fetchOne(
                $db->select()
                    ->from(['a' => $this->resource->getTableName('eav_attribute')], 'attribute_id')
                    ->join(['t' => $this->resource->getTableName('eav_entity_type')], 't.entity_type_id = a.entity_type_id', [])
                    ->where('t.entity_type_code = ?', $entity)
                    ->where('a.attribute_code = ?', $code)
            );
        }
        return $this->attributes[$key];
    }

    /** @return array<int, string> brand category id => brand name (children of "Brands" under the store root) */
    public function brandCategories(): array
    {
        if ($this->brands !== null) {
            return $this->brands;
        }
        $this->brands = [];
        $nameId = $this->attributeId('name', 'catalog_category');
        if (!$nameId) {
            return $this->brands;
        }
        $db = $this->resource->getConnection();
        $entity = $this->resource->getTableName('catalog_category_entity');
        $names = $this->resource->getTableName('catalog_category_entity_varchar');
        $root = (int)$this->storeManager->getStore()->getRootCategoryId();
        $parent = (int)$db->fetchOne(
            $db->select()
                ->from(['c' => $entity], 'entity_id')
                ->join(['n' => $names], 'n.entity_id = c.entity_id AND n.store_id = 0 AND n.attribute_id = ' . $nameId, [])
                ->where('c.parent_id = ?', $root)
                ->where('n.value = ?', 'Brands')
                ->limit(1)
        );
        if (!$parent) {
            return $this->brands;
        }
        $rows = $db->fetchPairs(
            $db->select()
                ->from(['c' => $entity], 'entity_id')
                ->join(['n' => $names], 'n.entity_id = c.entity_id AND n.store_id = 0 AND n.attribute_id = ' . $nameId, ['value'])
                ->where('c.parent_id = ?', $parent)
        );
        foreach ($rows as $id => $name) {
            $this->brands[(int)$id] = (string)$name;
        }
        return $this->brands;
    }

    /**
     * Loads the card labels of these products in two queries.
     *
     * @param int[] $productIds
     */
    public function preload(array $productIds): void
    {
        $ids = array_values(array_diff(array_unique(array_map('intval', $productIds)), array_keys($this->labels)));
        if (!$ids) {
            return;
        }
        $db = $this->resource->getConnection();
        $brands = $this->brandCategories();
        $brandOf = [];
        if ($brands) {
            foreach ($db->fetchAll(
                $db->select()
                    ->from($this->resource->getTableName('catalog_category_product'), ['product_id', 'category_id'])
                    ->where('product_id IN (?)', $ids)
                    ->where('category_id IN (?)', array_keys($brands))
            ) as $row) {
                $brandOf[(int)$row['product_id']] ??= $brands[(int)$row['category_id']] ?? '';
            }
        }
        $fitment = [];
        $fitId = $this->attributeId('cz_fitment');
        if ($fitId) {
            $fitment = $db->fetchPairs(
                $db->select()
                    ->from($this->resource->getTableName('catalog_product_entity_text'), ['entity_id', 'value'])
                    ->where('attribute_id = ?', $fitId)
                    ->where('store_id = ?', 0)
                    ->where('entity_id IN (?)', $ids)
            );
        }
        foreach ($ids as $id) {
            $brand = trim((string)($brandOf[$id] ?? ''));
            $this->labels[$id] = $brand !== '' ? $brand : $this->fitmentLabel((string)($fitment[$id] ?? ''));
        }
    }

    /** Brand, else "Universal" or the vehicle make when the fitment says so, else ''. */
    public function cardLabel(int $productId): string
    {
        $this->preload([$productId]);
        return $this->labels[$productId] ?? '';
    }

    private function fitmentLabel(string $fitment): string
    {
        $makes = [];
        foreach (preg_split('/\R/', $fitment) ?: [] as $line) {
            $line = trim($line);
            if (strcasecmp($line, 'universal') === 0) {
                return (string)__('Universal');
            }
            if (strncmp($line, 'V:', 2) === 0) {
                $make = trim(explode('|', substr($line, 2))[0] ?? '');
                if ($make !== '') {
                    $makes[mb_strtolower($make)] = $make;
                }
            }
        }
        if (count($makes) === 1) {
            return (string)reset($makes);
        }
        return $makes ? (string)__('Multi-fit') : '';
    }

    /**
     * Parts that fit every vehicle, newest first: those the POS marks "universal"
     * and those without any vehicle fitment line.
     *
     * @return int[]
     */
    public function universalProductIds(int $limit): array
    {
        $db = $this->resource->getConnection();
        $select = $db->select()
            ->from(['e' => $this->resource->getTableName('catalog_product_entity')], 'entity_id')
            ->order('e.entity_id DESC')
            ->limit($limit);
        $fitId = $this->attributeId('cz_fitment');
        if ($fitId) {
            $select->joinLeft(
                ['f' => $this->resource->getTableName('catalog_product_entity_text')],
                'f.entity_id = e.entity_id AND f.store_id = 0 AND f.attribute_id = ' . $fitId,
                []
            )->where(
                "f.value IS NULL OR f.value NOT LIKE '%V:%' OR f.value LIKE 'universal%' OR f.value LIKE ?",
                "%\nuniversal%"
            );
        }
        return array_map('intval', $db->fetchCol($select));
    }

    /**
     * Most ordered products of this store (Magento's bestseller report, refreshed
     * by cron), or [] while the report is empty.
     *
     * @return int[]
     */
    public function bestsellerProductIds(int $limit): array
    {
        $db = $this->resource->getConnection();
        $table = $this->resource->getTableName('sales_bestsellers_aggregated_yearly');
        if (!$db->isTableExists($table)) {
            return [];
        }
        return array_map('intval', $db->fetchCol(
            $db->select()
                ->from($table, ['product_id'])
                ->where('store_id = ?', (int)$this->storeManager->getStore()->getId())
                ->group('product_id')
                ->order(new \Zend_Db_Expr('SUM(qty_ordered) DESC'))
                ->limit($limit)
        ));
    }

    /** @return int[] every category in this store's tree (for cache tags) */
    public function storeCategoryIds(): array
    {
        $db = $this->resource->getConnection();
        $root = (int)$this->storeManager->getStore()->getRootCategoryId();
        return array_map('intval', $db->fetchCol(
            $db->select()
                ->from($this->resource->getTableName('catalog_category_entity'), 'entity_id')
                ->where('path LIKE ?', '1/' . $root . '/%')
        ));
    }
}
