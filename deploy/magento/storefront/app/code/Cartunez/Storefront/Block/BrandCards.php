<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Framework\App\ResourceConnection;
use Magento\Catalog\Model\ResourceModel\Category\CollectionFactory;
use Magento\Framework\DataObject\IdentityInterface;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * "Shop by brand" cards. The POS puts each published part in Brands > <brand>,
 * so every brand here opens a page with only that brand's parts.
 * A brand logo is optional: Catalog > Categories > Brands > <brand> > Content > Category Image.
 */
class BrandCards extends Template implements IdentityInterface
{
    /** @var array<int, array{name: string, url: string, image: ?string, count: int, id: int}>|null */
    private ?array $brands = null;
    private int $parentId = 0;
    /** @var int[] every brand category, also those without parts (for cache tags) */
    private array $childIds = [];

    public function __construct(
        Context $context,
        private readonly CollectionFactory $categories,
        private readonly ResourceConnection $resource,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    /**
     * @return array<int, array{name: string, url: string, image: ?string, count: int, id: int}>
     */
    public function getBrands(): array
    {
        if ($this->brands !== null) {
            return $this->brands;
        }
        $this->brands = [];
        $store = $this->_storeManager->getStore();
        $parent = $this->categories->create()
            ->setStoreId((int)$store->getId())
            ->addAttributeToFilter('name', 'Brands')
            ->addFieldToFilter('parent_id', (int)$store->getRootCategoryId())
            ->setPageSize(1)
            ->getFirstItem();
        if (!$parent->getId()) {
            return $this->brands;
        }
        $this->parentId = (int)$parent->getId();
        $children = $this->categories->create()
            ->setStoreId((int)$store->getId())
            ->addAttributeToSelect(['name', 'image', 'url_key', 'url_path'])
            ->addIsActiveFilter()
            ->addFieldToFilter('parent_id', $this->parentId)
            ->setOrder('name', 'ASC');
        $this->childIds = array_map('intval', $children->getAllIds());
        $counts = $this->visibleCounts((int)$store->getId(), $this->childIds);
        /** @var Category $brand */
        foreach ($children as $brand) {
            $count = $counts[(int)$brand->getId()] ?? 0;
            if ($count < 1) {
                continue;
            }
            $image = null;
            try {
                $image = $brand->getImageUrl() ?: null;
            } catch (\Throwable $e) {
                $image = null;
            }
            $this->brands[] = [
                'id' => (int)$brand->getId(),
                'name' => (string)$brand->getName(),
                'url' => (string)$brand->getUrl(),
                'image' => $image,
                'count' => $count,
            ];
        }
        return $this->brands;
    }

    /**
     * Parts shown in each brand: enabled and visible products only, from Magento's
     * category product index for this store (updated by the indexer cron).
     *
     * @param int[] $categoryIds
     * @return array<int, int>
     */
    private function visibleCounts(int $storeId, array $categoryIds): array
    {
        if (!$categoryIds) {
            return [];
        }
        $db = $this->resource->getConnection();
        $table = $this->resource->getTableName('catalog_category_product_index_store' . $storeId);
        if (!$db->isTableExists($table)) {
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

    /** Up to two letters for a brand without a logo ("Bosch" -> "BO", "Motorline Demo" -> "MD"). */
    public function initials(string $name): string
    {
        $words = preg_split('/[^\p{L}\p{N}]+/u', $name, -1, PREG_SPLIT_NO_EMPTY) ?: [$name];
        $text = count($words) > 1
            ? mb_substr($words[0], 0, 1) . mb_substr($words[1], 0, 1)
            : mb_substr($words[0], 0, 2);
        return mb_strtoupper($text);
    }

    public function getIdentities(): array
    {
        $tags = [Category::CACHE_TAG];
        $this->getBrands();
        // Product assignments clean "cat_c_p_<id>"; category edits clean "cat_c_<id>".
        foreach (array_merge($this->parentId ? [$this->parentId] : [], $this->childIds) as $categoryId) {
            $tags[] = Category::CACHE_TAG . '_' . $categoryId;
            $tags[] = Product::CACHE_PRODUCT_CATEGORY_TAG . '_' . $categoryId;
        }
        return $tags;
    }
}
