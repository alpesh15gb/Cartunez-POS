<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\ResourceModel\Category\CollectionFactory;
use Magento\CatalogWidget\Block\Product\ProductsList;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\DataObject\IdentityInterface;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * "On sale" section of the home page. The POS puts every part an admin marked
 * on sale in the "Sale" category under the store root (and takes it out when
 * the sale is removed or ends), so this shows that category's products with
 * Magento's standard product grid: MRP struck through, the sale price, add to cart.
 * Shows nothing while the category is missing or has no visible products.
 */
class SaleProducts extends Template implements IdentityInterface
{
    public const CATEGORY_NAME = 'Sale';
    private const LIMIT = 12;

    private ?Category $category = null;
    private bool $loaded = false;
    private int $count = 0;
    private ?ProductsList $grid = null;

    public function __construct(
        Context $context,
        private readonly CollectionFactory $categories,
        private readonly ResourceConnection $resource,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    /** The active "Sale" category under this store's root, or null. */
    public function getSaleCategory(): ?Category
    {
        if ($this->loaded) {
            return $this->category;
        }
        $this->loaded = true;
        $store = $this->_storeManager->getStore();
        /** @var Category $found */
        $found = $this->categories->create()
            ->setStoreId((int)$store->getId())
            ->addAttributeToSelect(['name', 'url_key', 'url_path'])
            ->addAttributeToFilter('name', self::CATEGORY_NAME)
            ->addIsActiveFilter()
            ->addFieldToFilter('parent_id', (int)$store->getRootCategoryId())
            ->setPageSize(1)
            ->getFirstItem();
        if (!$found->getId()) {
            return null;
        }
        $this->category = $found;
        $this->count = $this->visibleCount((int)$store->getId(), (int)$found->getId());
        return $this->category;
    }

    /** Enabled, visible products in the Sale category (Magento's category product index). */
    public function getProductCount(): int
    {
        $this->getSaleCategory();
        return $this->count;
    }

    public function hasProducts(): bool
    {
        return $this->getSaleCategory() !== null && $this->count > 0;
    }

    public function getViewAllUrl(): string
    {
        $category = $this->getSaleCategory();
        return $category ? (string)$category->getUrl() : '';
    }

    /** The standard catalog widget grid filtered to the Sale category. */
    public function getGridHtml(): string
    {
        $category = $this->getSaleCategory();
        if ($category === null || $this->count < 1) {
            return '';
        }
        if ($this->grid === null) {
            $id = (int)$category->getId();
            $conditions = '^[`1`:^[`type`:`Magento||CatalogWidget||Model||Rule||Condition||Combine`,'
                . '`aggregator`:`all`,`value`:`1`,`new_child`:``^],'
                . '`1--1`:^[`type`:`Magento||CatalogWidget||Model||Rule||Condition||Product`,'
                . '`attribute`:`category_ids`,`operator`:`==`,`value`:`' . $id . '`^]^]';
            /** @var ProductsList $grid */
            $grid = $this->getLayout()->createBlock(
                ProductsList::class,
                'cz.sale.products.grid',
                [
                    'data' => [
                        'show_pager' => 0,
                        'products_count' => self::LIMIT,
                        'conditions_encoded' => $conditions,
                        'template' => 'Magento_CatalogWidget::product/widget/content/grid.phtml',
                    ],
                ]
            );
            $grid->setTemplate('Magento_CatalogWidget::product/widget/content/grid.phtml');
            $this->grid = $grid;
        }
        return (string)$this->grid->toHtml();
    }

    private function visibleCount(int $storeId, int $categoryId): int
    {
        $db = $this->resource->getConnection();
        $table = $this->resource->getTableName('catalog_category_product_index_store' . $storeId);
        if (!$db->isTableExists($table)) {
            return 0;
        }
        return (int)$db->fetchOne(
            $db->select()
                ->from($table, [new \Zend_Db_Expr('COUNT(DISTINCT product_id)')])
                ->where('category_id = ?', $categoryId)
                ->where('visibility IN (?)', [2, 4])
        );
    }

    public function getIdentities(): array
    {
        $tags = [Category::CACHE_TAG];
        $category = $this->getSaleCategory();
        if ($category !== null) {
            // Product assignments clean "cat_c_p_<id>"; category edits clean "cat_c_<id>".
            $tags[] = Category::CACHE_TAG . '_' . (int)$category->getId();
            $tags[] = Product::CACHE_PRODUCT_CATEGORY_TAG . '_' . (int)$category->getId();
        }
        if ($this->grid !== null) {
            $tags = array_merge($tags, $this->grid->getIdentities());
        }
        return array_values(array_unique($tags));
    }
}
