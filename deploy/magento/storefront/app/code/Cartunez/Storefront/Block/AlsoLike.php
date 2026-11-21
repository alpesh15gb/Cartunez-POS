<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Cartunez\Storefront\Model\ProductCategories;
use Magento\Catalog\Block\Product\AbstractProduct;
use Magento\Catalog\Block\Product\Context;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\Product\Attribute\Source\Status;
use Magento\Catalog\Model\Product\Visibility;
use Magento\Catalog\Model\ResourceModel\Product\CollectionFactory;
use Magento\Framework\DataObject\IdentityInterface;

/**
 * "You may also like" on the product page: up to 8 parts. The related products
 * set in Magento admin when there are any, otherwise other parts of the same
 * POS category or brand (never the "Sale" category). No stock information.
 */
class AlsoLike extends AbstractProduct implements IdentityInterface
{
    private const LIMIT = 8;

    /** @var Product[]|null */
    private ?array $items = null;

    public function __construct(
        Context $context,
        private readonly CollectionFactory $products,
        private readonly Visibility $visibility,
        private readonly ProductCategories $productCategories,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    /** @return Product[] */
    public function getItems(): array
    {
        if ($this->items !== null) {
            return $this->items;
        }
        $this->items = [];
        $product = $this->getProduct();
        if (!$product instanceof Product || !$product->getId()) {
            return $this->items;
        }
        $related = array_values(array_filter(array_map('intval', (array)$product->getRelatedProductIds())));
        $this->items = $related ? $this->load($product, $related, null) : [];
        if (!$this->items) {
            $similar = $this->productCategories->forProduct($product)['similar'];
            $this->items = $similar ? $this->load($product, null, $similar) : [];
        }
        return $this->items;
    }

    /**
     * @param int[]|null $ids
     * @param int[]|null $categoryIds
     * @return Product[]
     */
    private function load(Product $product, ?array $ids, ?array $categoryIds): array
    {
        $collection = $this->products->create();
        $collection->setStoreId((int)$this->_storeManager->getStore()->getId())
            ->addStoreFilter()
            ->addAttributeToSelect($this->_catalogConfig->getProductAttributes())
            ->addAttributeToFilter('status', Status::STATUS_ENABLED)
            ->setVisibility($this->visibility->getVisibleInCatalogIds())
            ->addPriceData()
            ->addUrlRewrite()
            ->addIdFilter([(int)$product->getId()], true);
        if ($ids !== null) {
            $collection->addIdFilter($ids);
        }
        if ($categoryIds !== null) {
            $collection->addCategoriesFilter(['in' => $categoryIds]);
        }
        $collection->setOrder('entity_id', 'DESC')->setPageSize(self::LIMIT)->setCurPage(1);
        return array_values($collection->getItems());
    }

    public function getIdentities(): array
    {
        $tags = [];
        $product = $this->getProduct();
        if ($product instanceof Product && $product->getId()) {
            $tags = $product->getIdentities();
        }
        foreach ($this->getItems() as $item) {
            $tags = array_merge($tags, $item->getIdentities());
        }
        return array_values(array_unique($tags));
    }
}
