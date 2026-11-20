<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Magento\Catalog\Model\Category;
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

    public function __construct(
        Context $context,
        private readonly CollectionFactory $categories,
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
            ->setLoadProductCount(true)
            ->setOrder('name', 'ASC');
        /** @var Category $brand */
        foreach ($children as $brand) {
            $count = (int)$brand->getProductCount();
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
        if ($this->parentId) {
            $tags[] = Category::CACHE_TAG . '_' . $this->parentId;
        }
        foreach ($this->getBrands() as $brand) {
            $tags[] = Category::CACHE_TAG . '_' . $brand['id'];
        }
        return $tags;
    }
}
