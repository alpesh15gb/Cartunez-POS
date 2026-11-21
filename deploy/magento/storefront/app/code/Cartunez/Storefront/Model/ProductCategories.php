<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Model;

use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\ResourceModel\Category\CollectionFactory;
use Magento\Store\Model\StoreManagerInterface;

/**
 * What the POS category links say about a part: its brand (the category under
 * "Brands" at the store root) and the categories to find similar parts in
 * (its own POS category and its brand, never the "Sale" category).
 */
class ProductCategories
{
    public const BRANDS = 'Brands';
    public const SALE = 'Sale';

    /** @var array<int, array{brand: ?Category, similar: int[]}> */
    private array $cache = [];

    public function __construct(
        private readonly CollectionFactory $categories,
        private readonly StoreManagerInterface $storeManager
    ) {
    }

    /** @return array{brand: ?Category, similar: int[]} */
    public function forProduct(Product $product): array
    {
        $id = (int)$product->getId();
        if (isset($this->cache[$id])) {
            return $this->cache[$id];
        }
        $result = ['brand' => null, 'similar' => []];
        $ids = array_values(array_filter(array_map('intval', (array)$product->getCategoryIds())));
        if ($ids) {
            $store = $this->storeManager->getStore();
            $rootId = (int)$store->getRootCategoryId();
            $brandsId = 0;
            $saleId = 0;
            $top = $this->categories->create()
                ->setStoreId((int)$store->getId())
                ->addAttributeToSelect('name')
                ->addAttributeToFilter('name', ['in' => [self::BRANDS, self::SALE]])
                ->addFieldToFilter('parent_id', $rootId);
            /** @var Category $category */
            foreach ($top as $category) {
                if ((string)$category->getName() === self::BRANDS) {
                    $brandsId = (int)$category->getId();
                } elseif ((string)$category->getName() === self::SALE) {
                    $saleId = (int)$category->getId();
                }
            }
            $own = $this->categories->create()
                ->setStoreId((int)$store->getId())
                ->addAttributeToSelect(['name', 'url_key', 'url_path'])
                ->addIdFilter($ids)
                ->addIsActiveFilter();
            foreach ($own as $category) {
                $categoryId = (int)$category->getId();
                if (in_array($categoryId, [$rootId, $brandsId, $saleId], true)) {
                    continue;
                }
                if ($brandsId && (int)$category->getParentId() === $brandsId && $result['brand'] === null) {
                    $result['brand'] = $category;
                }
                $result['similar'][] = $categoryId;
            }
        }
        return $this->cache[$id] = $result;
    }
}
