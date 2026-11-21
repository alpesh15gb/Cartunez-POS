<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Cartunez\Storefront\Model\Catalog;
use Magento\Catalog\Block\Product\AbstractProduct;
use Magento\Catalog\Block\Product\Context;
use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\Product\Attribute\Source\Status;
use Magento\Catalog\Model\Product\Visibility;
use Magento\Catalog\Model\ResourceModel\Product\CollectionFactory;
use Magento\Framework\DataObject\IdentityInterface;

/**
 * A row of product cards: "Best sellers" (Magento's bestseller report; newest
 * parts while it is empty), "New arrivals" (newest parts) or "Universal parts"
 * (fit every vehicle; shown under vehicle-finder results). A horizontal swipe
 * row on phones, a grid on desktop, with "View all"; shows nothing when empty.
 *
 * Data (CMS {{block}} parameters or layout arguments): list = best | new | universal |
 * request (from ?list=, for the /parts page), limit, mode = row | page, skip_if_best_empty.
 */
class ProductRow extends AbstractProduct implements IdentityInterface
{
    public const TYPE_BEST = 'best';
    public const TYPE_NEW = 'new';
    public const TYPE_UNIVERSAL = 'universal';
    private const ROW_LIMIT = 12;
    private const PAGE_LIMIT = 48;

    /** @var Product[]|null */
    private ?array $products = null;
    private bool $bestFallback = false;

    public function __construct(
        Context $context,
        private readonly CollectionFactory $productCollections,
        private readonly Visibility $visibility,
        private readonly Catalog $catalog,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    public static function normalizeType(string $type): string
    {
        $type = strtolower(trim($type));
        if ($type === 'bestsellers') {
            $type = self::TYPE_BEST;
        }
        return in_array($type, [self::TYPE_BEST, self::TYPE_NEW, self::TYPE_UNIVERSAL], true) ? $type : self::TYPE_NEW;
    }

    public static function title(string $type): \Magento\Framework\Phrase
    {
        return match ($type) {
            self::TYPE_BEST => __('Best sellers'),
            self::TYPE_UNIVERSAL => __('Universal parts'),
            default => __('New arrivals'),
        };
    }

    public function getType(): string
    {
        $type = (string)$this->getData('list');
        if ($type === 'request') {
            $type = (string)$this->getRequest()->getParam('list', self::TYPE_NEW);
        }
        return self::normalizeType($type);
    }

    public function isPage(): bool
    {
        return $this->getData('mode') === 'page';
    }

    private function limit(): int
    {
        $limit = (int)$this->getData('limit');
        return $limit > 0 ? min($limit, 60) : ($this->isPage() ? self::PAGE_LIMIT : self::ROW_LIMIT);
    }

    /** @return Product[] */
    public function getProducts(): array
    {
        if ($this->products !== null) {
            return $this->products;
        }
        $this->products = [];
        $limit = $this->limit();
        switch ($this->getType()) {
            case self::TYPE_BEST:
                $ids = $this->catalog->bestsellerProductIds($limit * 3);
                $this->products = $ids ? $this->load($ids, $limit) : [];
                if (!$this->products) {
                    // No orders reported yet: the newest parts instead.
                    $this->bestFallback = true;
                    $this->products = $this->load(null, $limit);
                }
                break;
            case self::TYPE_UNIVERSAL:
                // Under search results only for a vehicle-finder search ("marutisuzukiswift2020").
                if ($this->getData('vehicle_search_only') && !$this->isVehicleSearch()) {
                    break;
                }
                $ids = $this->catalog->universalProductIds(max(200, $limit * 4));
                $this->products = $ids ? $this->load($ids, $limit) : [];
                break;
            default:
                // On the home page the best-seller row already shows the newest
                // parts while there are no orders; this row then shows the next ones.
                $offset = !$this->isPage() && $this->getData('skip_if_best_empty')
                    && !$this->catalog->bestsellerProductIds(1) ? self::ROW_LIMIT : 0;
                $this->products = $this->load(null, $limit, $offset);
        }
        if ($this->products) {
            $this->catalog->preload(array_map(static fn (Product $p): int => (int)$p->getId(), $this->products));
        }
        return $this->products;
    }

    /** The search word the vehicle finder sends: make + model + year, lowercase letters and digits. */
    public function isVehicleSearch(): bool
    {
        $q = (string)$this->getRequest()->getParam('q', '');
        return preg_match('/^[a-z0-9]{2,}(19|20)\d{2}$/', $q) === 1;
    }

    public function isBestFallback(): bool
    {
        $this->getProducts();
        return $this->bestFallback;
    }

    /**
     * Enabled parts visible in the catalog of this store: the given ids in their
     * order, or the newest ones.
     *
     * @param int[]|null $ids
     * @return Product[]
     */
    private function load(?array $ids, int $limit, int $offset = 0): array
    {
        $collection = $this->productCollections->create();
        $collection->setStoreId((int)$this->_storeManager->getStore()->getId());
        $this->_addProductAttributesAndPrices($collection);
        $collection->addStoreFilter()
            ->setVisibility($this->visibility->getVisibleInCatalogIds())
            ->addAttributeToFilter('status', Status::STATUS_ENABLED);
        if ($ids !== null) {
            $collection->addIdFilter($ids)->setPageSize(count($ids))->setCurPage(1);
            $found = [];
            foreach ($collection as $product) {
                $found[(int)$product->getId()] = $product;
            }
            $ordered = [];
            foreach ($ids as $id) {
                if (isset($found[$id])) {
                    $ordered[] = $found[$id];
                }
            }
            return array_slice($ordered, 0, $limit);
        }
        $collection->setOrder('created_at', 'DESC')->setOrder('entity_id', 'DESC');
        $collection->getSelect()->limit($limit, $offset);
        return array_values($collection->getItems());
    }

    public function getCardLabel(Product $product): string
    {
        return $this->catalog->cardLabel((int)$product->getId());
    }

    public function getHeading(): string
    {
        if ($this->getType() === self::TYPE_BEST && $this->isBestFallback()) {
            return (string)__('Top picks');
        }
        return (string)self::title($this->getType());
    }

    public function getKicker(): string
    {
        return (string)match ($this->getType()) {
            self::TYPE_BEST => $this->isBestFallback() ? __('Fresh in the shop') : __('Most ordered'),
            self::TYPE_UNIVERSAL => __('Fit every car'),
            default => __('Just in'),
        };
    }

    public function getViewAllUrl(): string
    {
        $type = $this->getType() === self::TYPE_BEST && $this->isBestFallback() ? self::TYPE_NEW : $this->getType();
        return $this->getUrl('parts', ['list' => $type]);
    }

    /** True when the part can go straight into the cart from the card. */
    public function canAddFromList(Product $product): bool
    {
        try {
            return (bool)$product->getTypeInstance()->isPossibleBuyFromList($product);
        } catch (\Throwable $e) {
            return false;
        }
    }

    public function getIdentities(): array
    {
        $tags = [Product::CACHE_TAG];
        foreach ($this->getProducts() as $product) {
            $tags[] = Product::CACHE_TAG . '_' . (int)$product->getId();
        }
        if ($this->getType() !== self::TYPE_BEST || $this->isBestFallback()) {
            // New parts are added to a category: those tags clear the newest rows.
            foreach ($this->catalog->storeCategoryIds() as $id) {
                $tags[] = Product::CACHE_PRODUCT_CATEGORY_TAG . '_' . $id;
            }
            $tags[] = Category::CACHE_TAG;
        }
        return array_values(array_unique($tags));
    }
}
